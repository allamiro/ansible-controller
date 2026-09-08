#!/bin/bash
# Recover a mesh job whose results stream broke (results-incomplete) without
# re-executing anything: mesh-run --collect re-attaches to the tracked unit,
# records the real rc, exports artifacts, and frees the slot.
set -euo pipefail
JOB_ID="${1:?usage: mesh-collect.sh <mesh-job-uuid>  (set JOB_ID when triggering the collect job)}"

rc=0
/usr/local/mesh/bin/mesh-run --collect "$JOB_ID" 2>&1 | tee mesh-collect.log || rc=${PIPESTATUS[0]}

mkdir -p mesh-artifacts
cp mesh-collect.log mesh-artifacts/ 2>/dev/null || true
if [ -d "/var/lib/mesh/jobs/$JOB_ID" ]; then
  cp "/var/lib/mesh/jobs/$JOB_ID/meta.json" mesh-artifacts/ 2>/dev/null || true
  cp "/var/lib/mesh/jobs/$JOB_ID/artifacts/rc" mesh-artifacts/ansible-rc 2>/dev/null || true
  cp "/var/lib/mesh/jobs/$JOB_ID/artifacts/stdout" mesh-artifacts/ansible-stdout 2>/dev/null || true
fi
exit "$rc"
