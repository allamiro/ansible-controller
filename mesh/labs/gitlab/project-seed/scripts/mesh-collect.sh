#!/bin/bash
# Recover a mesh job without re-executing anything.
#
#   mesh-collect.sh <job-uuid>                # results-incomplete → real rc
#   RECONCILE=1 mesh-collect.sh <job-uuid>    # additionally: reconcile a STALE
#                                             # active record first
#
# Reconcile exists for the CI-specific failure mode where the deploy JOB
# CONTAINER was killed (cancel/timeout) before mesh-run could finalize, so
# meta.json is frozen at created/submitting/running and mesh-run --collect
# rightly refuses ("a dispatcher is streaming it") — but here the dispatcher
# is provably gone: it lived in the killed job container. Reconcile verifies
# the record is stale (untouched for >120s) and that no ingress reports the
# unit still Running, then transitions the record to the semantically correct
# state (results-incomplete / failed / submit-ambiguous) before collecting.
set -euo pipefail
JOB_ID="${1:?usage: [RECONCILE=1] mesh-collect.sh <mesh-job-uuid>}"
# One path segment only — a traversal like ../jobs/<other-id> must not let
# this script attach another job's artifacts to this pipeline.
case "$JOB_ID" in
  ''|.|..|*[!0-9a-fA-F-]*) echo "invalid JOB_ID '$JOB_ID' — expected a mesh job uuid" >&2; exit 2;;
esac
META="/var/lib/mesh/jobs/$JOB_ID/meta.json"

if [ "${RECONCILE:-0}" = "1" ] && [ -f "$META" ]; then
  status=$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$META" | tail -1)
  case "$status" in
    created|submitting|running)
      # Four independent staleness/liveness proofs before touching the record
      # — a detached dispatcher can survive a GitLab cancel (see README), so
      # "old meta" alone proves nothing:
      # (1) the record untouched for >120s;
      age=$(( $(date +%s) - $(stat -c %Y "$META") ))
      [ "$age" -gt 120 ] || { echo "record is only ${age}s old — a dispatcher may still be live; refusing to reconcile" >&2; exit 3; }
      # (2) the dispatcher's own slot lock is free: a live mesh-run (or its
      # children) holds an exclusive flock on the slot whose .hold names this
      # job — the implementation's own liveness signal;
      slot=$(grep -l "job=$JOB_ID" /var/lib/mesh/slots/*/slot.*.hold 2>/dev/null | head -1 | sed 's/\.hold$//' || true)
      if [ -n "$slot" ]; then
        if ! flock -n "$slot" true 2>/dev/null; then
          echo "slot lock $slot is still held — a dispatcher process is alive; refusing to reconcile" >&2; exit 3
        fi
      else
        # No .hold names this job — a dispatcher dying between 'created' and
        # writing the marker leaves exactly this shape, but so does one still
        # ALIVE in that window (it already holds a slot flock). This collect
        # job shares the deploy jobs' resource_group, so no legitimate
        # dispatch runs concurrently: ANY held slot lock here means a
        # surviving dispatcher — refuse.
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
      # (4) at least one ingress probe SUCCEEDS and none reports the unit
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
      # atomic rewrite, stamping the transition time like the dispatcher does
      python3 - "$META" "$status" "$newstatus" <<'PY'
import json, os, sys, tempfile, datetime
path, old, new = sys.argv[1:4]
with open(path) as f: m = json.load(f)
if m.get("status") != old: sys.exit(f"status changed underneath us ({m.get('status')!r}) — aborting")
m["status"] = new
m["updated"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S%z")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w") as f: json.dump(m, f)
os.replace(tmp, path)
PY
      ;;
  esac
fi

rc=0
/usr/local/mesh/bin/mesh-run --collect "$JOB_ID" 2>&1 | tee mesh-collect.log || rc=${PIPESTATUS[0]}

mkdir -p mesh-artifacts
cp mesh-collect.log mesh-artifacts/ 2>/dev/null || true
if [ -d "/var/lib/mesh/jobs/$JOB_ID" ]; then
  cp "$META" mesh-artifacts/ 2>/dev/null || true
  rcf=$(find "/var/lib/mesh/jobs/$JOB_ID/artifacts" -maxdepth 2 -name rc 2>/dev/null | head -1 || true)
  [ -n "$rcf" ] && { cp "$rcf" mesh-artifacts/ansible-rc 2>/dev/null || true
    cp "$(dirname "$rcf")/stdout" mesh-artifacts/ansible-stdout 2>/dev/null || true; }
fi
exit "$rc"
