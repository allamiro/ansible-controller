#!/bin/bash
# Dispatch the reviewed commit's playbook through the Receptor mesh.
# Runs inside the deploy job container (ansible-orchestrator image) with:
#   /run/receptor     control sockets  (submission authority)
#   /var/lib/mesh     job state — meta.json, slots, artifacts
#   /e2e-ssh          the lab's disposable target key (read-only)
set -euo pipefail

: "${MESH_NODE:?}" "${PLAYBOOK:?}" "${MESH_WAIT:=60}"
[ "${DEPLOY_ALLOWED:-}" = "true" ] || {
  echo "DEPLOY_ALLOWED is not visible — this is not a protected-ref pipeline; refusing." >&2
  exit 1
}

# --- no-resubmission guard -------------------------------------------------
# A GitLab retry of this job must never silently duplicate an operation whose
# outcome is unknown. mesh-run itself never auto-resubmits within one
# invocation; this guard extends that boundary across CI retries: while ANY
# tracked job is non-final, dispatching is refused and the operator must run
# the collect job (or inspect the mesh state) first.
unresolved=""
for m in /var/lib/mesh/jobs/*/meta.json; do
  [ -f "$m" ] || continue
  s=$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$m" | tail -1)
  case "$s" in
    submitting|running|submit-ambiguous|results-incomplete)
      unresolved="$unresolved $(basename "$(dirname "$m")")($s)";;
  esac
done
if [ -n "$unresolved" ]; then
  echo "REFUSING to dispatch — unresolved mesh job(s):$unresolved" >&2
  echo "Recover first: run the 'collect' job with JOB_ID=<uuid>, or inspect /var/lib/mesh/jobs/<uuid>/meta.json." >&2
  exit 1
fi

# --- bind the play to the reviewed commit -----------------------------------
# The runner checked out the immutable $CI_COMMIT_SHA; stamp it into the vars
# the playbook records on the target, so the managed host itself carries the
# provenance of what was applied.
cat > playbooks/vars/commit.yml <<EOF
lab_commit: "${CI_COMMIT_SHA:-unknown}"
lab_pipeline: "${CI_PIPELINE_ID:-unknown}"
EOF

echo "Dispatching commit ${CI_COMMIT_SHA:-?} -> node ${MESH_NODE} (${PLAYBOOK}, wait ${MESH_WAIT}s)"
rc=0
/usr/local/mesh/bin/mesh-run \
  --node "$MESH_NODE" \
  --playbook "$CI_PROJECT_DIR/playbooks/$PLAYBOOK" \
  --inventory "$CI_PROJECT_DIR/inventory/lab.ini" \
  --ssh-key /e2e-ssh/id_ed25519 \
  --wait "$MESH_WAIT" 2>&1 | tee mesh-run.log || rc=${PIPESTATUS[0]}

# --- sanitized artifacts -----------------------------------------------------
# meta.json + the runner rc + stdout ONLY. Never the private data dir's env/
# (it can stage credentials) and never the SSH key.
job=$(grep -o 'job=[0-9a-f-]*' mesh-run.log | head -1 | cut -d= -f2 || true)
# a broken results stream can end the run before mesh-run prints its
# completion line — fall back to the newest tracked job so the collect
# handoff always has an id
if [ -z "$job" ]; then
  job=$(ls -1t /var/lib/mesh/jobs 2>/dev/null | head -1 || true)
fi
mkdir -p mesh-artifacts
{
  echo "commit=${CI_COMMIT_SHA:-}"
  echo "pipeline=${CI_PIPELINE_ID:-}"
  echo "mesh_job=${job:-none}"
  echo "mesh_rc=$rc"
} > mesh-artifacts/provenance.txt
cp mesh-run.log mesh-artifacts/ 2>/dev/null || true
if [ -n "$job" ] && [ -d "/var/lib/mesh/jobs/$job" ]; then
  cp "/var/lib/mesh/jobs/$job/meta.json" mesh-artifacts/ 2>/dev/null || true
  cp "/var/lib/mesh/jobs/$job/artifacts/rc" mesh-artifacts/ansible-rc 2>/dev/null || true
  cp "/var/lib/mesh/jobs/$job/artifacts/stdout" mesh-artifacts/ansible-stdout 2>/dev/null || true
fi

echo "mesh job=${job:-none} rc=$rc"
exit "$rc"
