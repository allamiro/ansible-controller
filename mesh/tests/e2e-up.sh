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
# A bundle counts as reusable only when COMPLETE (crt+key+ca) AND LIVE — an
# interrupted earlier run can leave a partial bundle, and e2e-down.sh
# deliberately retains .e2e-pki, so a retained bundle can also outlive its
# one-year leaf validity. Either way it must regenerate here, not get mounted
# into a container to fail `compose up --wait` obscurely there. LIVE means
# valid for 24h more, so a cert cannot expire mid-suite. (Host openssl is the
# only tool this adds — present on the CI runners and any docker-capable dev
# host; the PKI itself still runs in the pinned image via mesh/pki/.)
bundle_files() { [ -f "$1/tls.crt" ] && [ -f "$1/tls.key" ] && [ -f "$1/ca.crt" ]; }
cert_live()    { openssl x509 -in "$1" -noout -checkend 86400 >/dev/null 2>&1; }
bundle_ok()    { bundle_files "$1" && cert_live "$1/tls.crt"; }
# The CA must be a COMPLETE pair with a LIVE cert. Half a pair is
# unrecoverable in place (init refuses an existing crt; issuance needs both),
# an expired CA fails every handshake just as obscurely, and this CA is a
# throwaway — so either condition wipes the WHOLE e2e PKI and starts over:
# a new CA orphans every previously issued bundle anyway.
if ! { [ -f "$PKI_DIR/ca/ca.key" ] && [ -f "$PKI_DIR/ca/ca.crt" ] && cert_live "$PKI_DIR/ca/ca.crt"; }; then
  rm -rf "$PKI_DIR"
  mesh/pki/mesh-ca-init.sh "mesh-e2e throwaway CA"
fi
# Work-signing keypair (Phase 9): ingresses sign, the node verifies. Like the
# retained cert bundles, retained keys are VALIDATED, not merely present: a
# truncated private key or a public half from an older rotation would fail the
# suite obscurely at compose-up. The pair is good only if the private key
# parses AND its derived public key matches the stored one byte for byte.
signing_pair_ok() {
  local d="$PKI_DIR/work-signing" derived
  [ -f "$d/work-private.pem" ] && [ -f "$d/work-public.pem" ] || return 1
  derived=$(openssl pkey -in "$d/work-private.pem" -pubout 2>/dev/null) || return 1
  [ "$derived" = "$(cat "$d/work-public.pem")" ]
}
if ! signing_pair_ok; then
  rm -rf "$PKI_DIR/work-signing"
  mesh/pki/work-sign-init.sh
fi
bundle_ok "$PKI_DIR/issued/controller-a" || { rm -rf "$PKI_DIR/issued/controller-a"; mesh/pki/controller-cert.sh controller-a mesh-e2e-receptor; }
bundle_ok "$PKI_DIR/issued/controller-b" || { rm -rf "$PKI_DIR/issued/controller-b"; mesh/pki/controller-cert.sh controller-b mesh-e2e-receptor-b; }
if ! bundle_ok "$PKI_DIR/issued/exec-e2e-a"; then
  rm -rf "$PKI_DIR/issued/exec-e2e-a"
  { [ -f "$PKI_DIR/csr/exec-e2e-a.csr" ] && [ -f "$PKI_DIR/csr/exec-e2e-a.key" ]; } \
    || { rm -f "$PKI_DIR/csr/exec-e2e-a.csr" "$PKI_DIR/csr/exec-e2e-a.key"; mesh/pki/node-csr.sh exec-e2e-a; }
  mesh/pki/node-sign.sh csr/exec-e2e-a.csr exec-e2e-a
  cp "$PKI_DIR/csr/exec-e2e-a.key" "$PKI_DIR/issued/exec-e2e-a/tls.key"
fi
# an EXPIRED-but-otherwise-valid identity (real CA, notAfter in the past) for
# the §9.3 expired-cert rejection test. Its guard is the fixture's own, NOT
# bundle_ok: bundle_ok now rejects expired certs, which would regenerate this
# fixture every run — and the fixture must be strictly expired RIGHT NOW
# (parseable, -checkend 0 failing), because a nearly-expired-but-still-valid
# cert would be ACCEPTED by the ingress and falsify check 18.
fixture_expired_ok() {
  bundle_files "$1" \
    && openssl x509 -in "$1/tls.crt" -noout >/dev/null 2>&1 \
    && ! openssl x509 -in "$1/tls.crt" -noout -checkend 0 >/dev/null 2>&1
}
if ! fixture_expired_ok "$PKI_DIR/issued/exec-expired"; then
  rm -rf "$PKI_DIR/issued/exec-expired"
  CERT_NOT_AFTER="$(date -u -d "-1 day" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v -1d +%Y-%m-%dT%H:%M:%SZ)" \
    mesh/pki/controller-cert.sh exec-expired
fi
# a valid probe identity for the reversed §9.3 test (node must reject a
# CONTROLLER whose cert comes from an unknown CA)
bundle_ok "$PKI_DIR/issued/exec-probe" || { rm -rf "$PKI_DIR/issued/exec-probe"; mesh/pki/controller-cert.sh exec-probe; }
# a SECOND, unrelated CA — the §9.3 unknown-CA negative test needs a cert
# that is cryptographically valid but signed by a stranger
if ! { [ -f "$PKI_DIR/rogue/ca/ca.key" ] && [ -f "$PKI_DIR/rogue/ca/ca.crt" ] && cert_live "$PKI_DIR/rogue/ca/ca.crt"; }; then
  rm -rf "$PKI_DIR/rogue"
  MESH_SECRETS="$PKI_DIR/rogue" mesh/pki/mesh-ca-init.sh "rogue CA"
fi
bundle_ok "$PKI_DIR/rogue/issued/exec-rogue" || { rm -rf "$PKI_DIR/rogue/issued/exec-rogue"; MESH_SECRETS="$PKI_DIR/rogue" mesh/pki/controller-cert.sh exec-rogue; }
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
