#!/bin/bash
# Recover a mesh job without re-executing anything.
#
#   mesh-collect.sh <job-uuid>                    # results-incomplete → real rc
#   RECONCILE=1 mesh-collect.sh <job-uuid>        # reconcile a STALE active record first
#   RESOLVE_AMBIGUOUS=failed    mesh-collect.sh <job-uuid>   # operator verdict: nothing ran
#   RESOLVE_AMBIGUOUS=<unit-id> mesh-collect.sh <job-uuid>   # operator verdict: adopt this unit
#
# RECONCILE exists for the CI-specific failure mode where the deploy JOB
# CONTAINER was killed (cancel/timeout) before mesh-run could finalize, so
# meta.json is frozen at created/submitting/running and mesh-run --collect
# rightly refuses ("a dispatcher is streaming it") — but here the dispatcher
# is provably gone. It demands independent staleness/liveness proofs before
# touching anything (see inline).
#
# RESOLVE_AMBIGUOUS records a HUMAN verdict on a submit-ambiguous record,
# after the operator followed the lab README's work-list procedure: either
# nothing left the ingress layer (failed), or a specific unit was identified
# as this job's (adopt: unit id + results-incomplete, then a normal collect
# picks up its real rc). The script only performs the bookkeeping atomically;
# the judgment stays with the human.
set -euo pipefail
JOB_ID="${1:?usage: [RECONCILE=1 | RESOLVE_AMBIGUOUS=failed|<unit-id>] mesh-collect.sh <mesh-job-uuid>}"
# One path segment only — a traversal like ../jobs/<other-id> must not let
# this script attach another job's artifacts to this pipeline.
case "$JOB_ID" in
  ''|.|..|*[!0-9a-fA-F-]*) echo "invalid JOB_ID '$JOB_ID' — expected a mesh job uuid" >&2; exit 2;;
esac
META="/var/lib/mesh/jobs/$JOB_ID/meta.json"

meta_status() { sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$META" | tail -1; }
meta_transition() { # expected-status new-status [unit-id] — atomic, stamps updated
  python3 - "$META" "$1" "$2" "${3:-}" <<'PY'
import json, os, sys, tempfile, datetime
path, old, new, unit = sys.argv[1:5]
with open(path) as f: m = json.load(f)
if m.get("status") != old: sys.exit(f"status changed underneath us ({m.get('status')!r}) — aborting")
m["status"] = new
if unit: m["unit_id"] = unit
m["updated"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S%z")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w") as f: json.dump(m, f)
os.replace(tmp, path)
PY
}
export_artifacts() { # copies the sanitized set; never env/, never keys
  mkdir -p mesh-artifacts
  cp mesh-collect.log mesh-artifacts/ 2>/dev/null || true
  [ -f "$META" ] && cp "$META" mesh-artifacts/ 2>/dev/null || true
  local rcf
  rcf=$(find "/var/lib/mesh/jobs/$JOB_ID/artifacts" -maxdepth 2 -name rc 2>/dev/null | head -1 || true)
  if [ -n "$rcf" ]; then   # a bare && tail would return 1 here and trip set -e
    cp "$rcf" mesh-artifacts/ansible-rc 2>/dev/null || true
    cp "$(dirname "$rcf")/stdout" mesh-artifacts/ansible-stdout 2>/dev/null || true
  fi
}
run_collect() {
  rc=0
  /usr/local/mesh/bin/mesh-run --collect "$JOB_ID" 2>&1 | tee mesh-collect.log || rc=${PIPESTATUS[0]}
  export_artifacts
  exit "$rc"
}

# ---- operator verdict on a submit-ambiguous record --------------------------
if [ -n "${RESOLVE_AMBIGUOUS:-}" ]; then
  [ -f "$META" ] || { echo "no record at $META" >&2; exit 2; }
  status=$(meta_status)
  [ "$status" = submit-ambiguous ] || { echo "RESOLVE_AMBIGUOUS applies only to submit-ambiguous records (status=$status)" >&2; exit 2; }
  if [ "$RESOLVE_AMBIGUOUS" = failed ]; then
    meta_transition submit-ambiguous failed
    echo "recorded operator verdict: nothing executed (failed). Clear this job's slot .hold per the README's step 3."
    : > mesh-collect.log; export_artifacts; exit 0
  else
    case "$RESOLVE_AMBIGUOUS" in *[!0-9A-Za-z._-]*|'') echo "invalid unit id '$RESOLVE_AMBIGUOUS'" >&2; exit 2;; esac
    meta_transition submit-ambiguous results-incomplete "$RESOLVE_AMBIGUOUS"
    echo "adopted unit $RESOLVE_AMBIGUOUS — collecting its real result"
    run_collect
  fi
fi

# ---- stale active-record reconciliation -------------------------------------
if [ "${RECONCILE:-0}" = "1" ] && [ -f "$META" ]; then
  status=$(meta_status)
  case "$status" in
    created|submitting|running)
      # Independent staleness/liveness proofs before touching the record —
      # a detached dispatcher can survive a GitLab cancel (see README), so
      # "old meta" alone proves nothing:
      # (1) the record untouched for >120s;
      age=$(( $(date +%s) - $(stat -c %Y "$META") ))
      [ "$age" -gt 120 ] || { echo "record is only ${age}s old — a dispatcher may still be live; refusing to reconcile" >&2; exit 3; }
      # (2) the dispatcher's own slot lock is free: a live mesh-run (or its
      # children) holds an exclusive flock on the slot whose .hold names this
      # job. With no .hold (death in the pre-marker window), ANY held slot
      # lock refuses — this collect job shares the deploys' resource_group,
      # so no legitimate dispatch runs concurrently.
      slot=$(grep -l "job=$JOB_ID" /var/lib/mesh/slots/*/slot.*.hold 2>/dev/null | head -1 | sed 's/\.hold$//' || true)
      if [ -n "$slot" ]; then
        if ! flock -n "$slot" true 2>/dev/null; then
          echo "slot lock $slot is still held — a dispatcher process is alive; refusing to reconcile" >&2; exit 3
        fi
      else
        for sl in /var/lib/mesh/slots/*/slot.[0-9]*; do
          [ -e "$sl" ] || continue
          case "$sl" in *.hold) continue;; esac
          if ! flock -n "$sl" true 2>/dev/null; then
            echo "slot lock $sl is held with no marker for this job — a dispatcher is alive somewhere; refusing to reconcile" >&2; exit 3
          fi
        done
      fi
      # (3) the whole job tree quiescent for 60s (a surviving dispatcher
      # streaming results writes into artifacts/ continuously). An
      # UNINSPECTABLE tree is unknown, not quiescent — fail closed.
      if ! recent=$(find "/var/lib/mesh/jobs/$JOB_ID" -newermt '-60 seconds' -print -quit 2>&1); then
        echo "cannot inspect the job tree ($recent) — refusing to reconcile" >&2; exit 3
      fi
      if [ -n "$recent" ]; then
        echo "job tree changed within the last 60s — something is still writing; refusing to reconcile" >&2; exit 3
      fi
      # (4) if the AUTHORITATIVE rc artifact already exists, the play
      # finished and only the terminal meta write was lost (killed between
      # rc export and the status update, possibly after the unit was
      # released) — finalize directly from the artifact instead of trying
      # to re-attach to a unit that may no longer exist anywhere.
      rcart=$(find "/var/lib/mesh/jobs/$JOB_ID/artifacts" -maxdepth 2 -name rc 2>/dev/null | head -1 || true)
      if [ -n "$rcart" ] && rcval=$(tr -dc 0-9 < "$rcart") && [ -n "$rcval" ]; then
        if [ "$rcval" = 0 ]; then newstatus=succeeded; else newstatus="failed rc=$rcval"; fi
        echo "rc artifact already present (rc=$rcval) — finalizing '$status' -> '$newstatus'"
        meta_transition "$status" "$newstatus"
        run_collect   # terminal status → collect ensures unit/slot cleanup, exits with the recorded rc
      fi
      # (5) at least one ingress probe SUCCEEDS and none reports the unit
      # Running — probe failure is not evidence of anything (fail closed).
      unit=$(sed -n 's/.*"unit_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$META" | tail -1)
      if [ -n "$unit" ]; then
        probe_ok=0
        for s in /run/receptor/receptor.sock /run/receptor/receptor-b.sock; do
          out=$(receptorctl --socket "$s" work list 2>/dev/null) || continue
          probe_ok=1
          state=$(printf '%s' "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$unit',{}).get('StateName',''))" 2>/dev/null || echo PARSE-ERROR)
          case "$state" in
            Running) echo "unit $unit is still Running on $s — refusing to reconcile" >&2; exit 3;;
            PARSE-ERROR) echo "could not parse work list from $s — refusing to reconcile" >&2; exit 3;;
          esac
        done
        [ "$probe_ok" = 1 ] || { echo "no ingress answered a work-list probe — cannot prove the unit stopped; refusing to reconcile" >&2; exit 3; }
        newstatus=results-incomplete   # dispatcher gone, unit known → collect can re-attach
      elif [ "$status" = "created" ]; then
        newstatus=failed               # nothing ever left this host
      else
        newstatus=submit-ambiguous     # submit may have left the host; operator work-list procedure
      fi
      echo "reconciling stale '$status' record (age ${age}s, unit '${unit:-none}') -> $newstatus"
      meta_transition "$status" "$newstatus"
      ;;
  esac
fi

run_collect
