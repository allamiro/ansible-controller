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
      age=$(( $(date +%s) - $(stat -c %Y "$META") ))
      [ "$age" -gt 120 ] || { echo "record is only ${age}s old — a dispatcher may still be live; refusing to reconcile" >&2; exit 3; }
      unit=$(sed -n 's/.*"unit_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$META" | tail -1)
      if [ -n "$unit" ]; then
        # the unit must not be actively Running on any live ingress
        for s in /run/receptor/receptor.sock /run/receptor/receptor-b.sock; do
          state=$(receptorctl --socket "$s" work list 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$unit',{}).get('StateName',''))" 2>/dev/null || true)
          [ "$state" = "Running" ] && { echo "unit $unit is still Running on $s — not stale; refusing to reconcile" >&2; exit 3; }
        done
        newstatus=results-incomplete   # dispatcher gone, unit known → collect can re-attach
      elif [ "$status" = "created" ]; then
        newstatus=failed               # nothing ever left this host
      else
        newstatus=submit-ambiguous     # submit may have left the host; operator work-list procedure
      fi
      echo "reconciling stale '$status' record (age ${age}s, unit '${unit:-none}') -> $newstatus"
      sed -i "s/\"status\": \"$status\"/\"status\": \"$newstatus\"/" "$META"
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
