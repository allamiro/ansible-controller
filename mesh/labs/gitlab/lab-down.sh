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
# The lab's resources are created under these fixed project names; a caller's
# COMPOSE_PROJECT_NAME would silently retarget the teardown.
unset COMPOSE_PROJECT_NAME
fail=0

echo "==> removing leftover runner JOB containers (lab network only)"
# Scope strictly to containers attached to THIS lab's network — a host-wide
# name filter could kill another GitLab Runner's unrelated jobs. -a includes
# jobs already stopped by a runner interruption. The stack's own two
# containers are excluded; compose down removes them with their network.
for c in $(docker ps -aq --filter network=gitlab-lab_labnet); do
  name=$(docker inspect -f '{{.Name}}' "$c" | tr -d /)
  case "$name" in gitlab-lab-gitlab|gitlab-lab-runner) continue;; esac
  docker rm -f "$c" >/dev/null && echo "    removed job container $name"
done

echo "==> gitlab-lab stack (containers + volumes)"
docker compose -f "$LAB/compose.gitlab.yml" down -v --remove-orphans || fail=1

echo "==> mesh e2e environment"
mesh/tests/e2e-down.sh || fail=1

if [ "$fail" -ne 0 ]; then
  echo "ERROR: a teardown step failed — resources may remain; NOT purging state." >&2
  exit 1
fi
if [ "${1:-}" = "--purge" ]; then
  echo "==> purging lab state and throwaway PKI"
  rm -rf "$LAB/.lab-state" mesh/tests/.e2e-pki
fi
echo "==> lab is down"
