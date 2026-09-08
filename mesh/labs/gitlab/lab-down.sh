#!/bin/bash
# Tear the GitLab integration lab down completely.
#
# ORDER MATTERS: the gitlab-lab stack goes first, because deploy JOB
# containers (created by the runner) mount mesh-e2e named volumes — the mesh
# teardown removes those volumes and would fail (or strand state) while a job
# container still holds them. e2e-down.sh then removes the mesh containers,
# networks, and volumes; it deliberately retains mesh/tests/.e2e-pki (the
# throwaway CA) so a later lab-up reuses working certificates — delete that
# directory too for a from-scratch PKI.
#
#   mesh/labs/gitlab/lab-down.sh          # remove lab + mesh, keep .lab-state and .e2e-pki
#   mesh/labs/gitlab/lab-down.sh --purge  # also delete .lab-state (tokens/passwords) and .e2e-pki
set -euo pipefail
cd "$(dirname "$0")/../../.."
LAB="mesh/labs/gitlab"

echo "==> stopping any leftover runner job containers"
docker ps -q --filter "name=runner-" | xargs -r docker rm -f

echo "==> gitlab-lab stack (containers + volumes)"
docker compose -f "$LAB/compose.gitlab.yml" down -v --remove-orphans || true

echo "==> mesh e2e environment"
mesh/tests/e2e-down.sh || true

if [ "${1:-}" = "--purge" ]; then
  echo "==> purging lab state and throwaway PKI"
  rm -rf "$LAB/.lab-state" mesh/tests/.e2e-pki
fi
echo "==> lab is down"
