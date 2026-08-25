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

echo "==> issuing the e2e PKI (mesh/pki/ scripts against a throwaway CA)"
# Idempotent: an existing e2e CA is reused (mesh-ca-init refuses a second run
# by design), so repeated e2e-up calls keep working certs. Node keys are made
# readable to uid 1000 — the identity receptor runs as on the node — and only
# issued/ directories are ever mounted into containers: the CA key stays
# outside every runtime mount, exactly the plan §4 rule the suite must model.
PKI_DIR="$PWD/mesh/tests/.e2e-pki"
export MESH_SECRETS="$PKI_DIR"
# Each identity regenerates independently: an interrupted earlier run must not
# leave later identities permanently missing behind a single guard.
[ -f "$PKI_DIR/ca/ca.key" ] || mesh/pki/mesh-ca-init.sh "mesh-e2e throwaway CA"
[ -f "$PKI_DIR/issued/controller-a/tls.crt" ] || mesh/pki/controller-cert.sh controller-a mesh-e2e-receptor
[ -f "$PKI_DIR/issued/controller-b/tls.crt" ] || mesh/pki/controller-cert.sh controller-b mesh-e2e-receptor-b
if [ ! -f "$PKI_DIR/issued/exec-e2e-a/tls.key" ]; then
  [ -f "$PKI_DIR/csr/exec-e2e-a.csr" ] || mesh/pki/node-csr.sh exec-e2e-a
  mesh/pki/node-sign.sh csr/exec-e2e-a.csr exec-e2e-a
  cp "$PKI_DIR/csr/exec-e2e-a.key" "$PKI_DIR/issued/exec-e2e-a/tls.key"
fi
# a SECOND, unrelated CA — the §9.3 unknown-CA negative test needs a cert
# that is cryptographically valid but signed by a stranger
[ -f "$PKI_DIR/rogue/ca/ca.key" ] || MESH_SECRETS="$PKI_DIR/rogue" mesh/pki/mesh-ca-init.sh "rogue CA"
[ -f "$PKI_DIR/rogue/issued/exec-rogue/tls.crt" ] || MESH_SECRETS="$PKI_DIR/rogue" mesh/pki/controller-cert.sh exec-rogue
# uid-1000 readability for material mounted into uid-1000 containers
docker run --rm -u 0:0 -v "$PKI_DIR:/pki" --entrypoint sh ansible-execution-node:e2e -euc '
  chown -R 1000:1000 /pki/issued /pki/rogue/issued 2>/dev/null || true
  chmod 600 /pki/issued/*/tls.key /pki/rogue/issued/*/tls.key 2>/dev/null || true
  chmod 644 /pki/issued/*/tls.crt /pki/issued/*/ca.crt /pki/rogue/issued/*/tls.crt /pki/rogue/issued/*/ca.crt 2>/dev/null || true
'

echo "==> starting the e2e environment"
docker compose -f mesh/tests/e2e.compose.yml up -d --wait --wait-timeout 90 \
  || { docker compose -f mesh/tests/e2e.compose.yml ps; exit 1; }

echo "==> seeding the disposable SSH keypair"
# sshd reads authorized_keys per auth attempt, so seeding after start needs no
# restarts. The key exists only inside the suite's volumes and is destroyed by
# e2e-down.sh.
# Volume names derive from the compose project name. The file pins `name:
# mesh-e2e`, but COMPOSE_PROJECT_NAME overrides a pinned name, so honour it —
# hardcoding would seed volumes the running containers never mount.
proj="${COMPOSE_PROJECT_NAME:-mesh-e2e}"
docker run --rm -u root \
  -v "${proj}_e2e-ssh:/w" -v "${proj}_e2e-ssh-authorized:/a" \
  --entrypoint bash ansible-orchestrator:e2e -euc '
  [ -f /w/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -f /w/id_ed25519
  # Private key: owner-only and owned by uid 1000 (the user dispatch runs as on
  # both the orchestrator and the node) — OpenSSH refuses group/world-readable
  # private keys outright ("UNPROTECTED PRIVATE KEY"). Public half stays 0644.
  chown 1000:1000 /w/id_ed25519 /w/id_ed25519.pub
  chmod 600 /w/id_ed25519
  chmod 644 /w/id_ed25519.pub
  install -d -m 0700 -o 1000 -g 1000 /a
  install -m 600 -o 1000 -g 1000 /w/id_ed25519.pub /a/authorized_keys
'

echo "==> e2e environment is up:"
docker compose -f mesh/tests/e2e.compose.yml ps --format 'table {{.Name}}\t{{.Status}}'
