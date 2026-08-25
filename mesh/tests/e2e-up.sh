#!/bin/bash
# Build the mesh images from the current checkout and start the e2e environment.
# Usage:  mesh/tests/e2e-up.sh <controller-image>
set -euo pipefail
cd "$(dirname "$0")/../.."

BASE="${1:?usage: e2e-up.sh <controller-image>}"

echo "==> tagging ${BASE} as ansible-controller:e2e (the suite's managed target)"
docker tag "${BASE}" ansible-controller:e2e

echo "==> building orchestrator + execution-node from ${BASE}"
docker build -f docker/mesh/Dockerfile --target orchestrator \
  --build-arg BASE="${BASE}" --build-arg ALLOW_MUTABLE_BASE=1 \
  -t ansible-orchestrator:e2e .
docker build -f docker/mesh/Dockerfile --target execution-node \
  --build-arg BASE="${BASE}" --build-arg ALLOW_MUTABLE_BASE=1 \
  -t ansible-execution-node:e2e .

echo "==> starting the e2e environment"
docker compose -f mesh/tests/e2e.compose.yml up -d --wait --wait-timeout 90 \
  || { docker compose -f mesh/tests/e2e.compose.yml ps; exit 1; }

echo "==> seeding the disposable SSH keypair"
# sshd reads authorized_keys per auth attempt, so seeding after start needs no
# restarts. The key exists only inside the suite's volumes and is destroyed by
# e2e-down.sh.
docker run --rm -u root \
  -v mesh-e2e_e2e-ssh:/w -v mesh-e2e_e2e-ssh-authorized:/a \
  --entrypoint bash ansible-orchestrator:e2e -euc '
  [ -f /w/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -f /w/id_ed25519
  chmod 644 /w/id_ed25519 /w/id_ed25519.pub
  install -d -m 0700 -o 1000 -g 1000 /a
  install -m 600 -o 1000 -g 1000 /w/id_ed25519.pub /a/authorized_keys
'

echo "==> e2e environment is up:"
docker compose -f mesh/tests/e2e.compose.yml ps --format 'table {{.Name}}\t{{.Status}}'
