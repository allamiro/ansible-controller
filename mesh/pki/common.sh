#!/bin/bash
# Shared plumbing for the mesh PKI scripts. Everything runs receptor's own
# cert tooling inside the digest-pinned receptor image, so the operator needs
# no local receptor install and every environment issues identical certs.
#
# Layout (all under $MESH_SECRETS, default mesh/secrets/receptor — gitignored;
# mesh/.gitignore refuses key material anywhere under mesh/ as a backstop):
#   ca/ca.crt  ca/ca.key      the mesh CA  (ca.key: OFFLINE storage — never
#                             on a runtime container; plan §2.3/§4)
#   issued/<name>/tls.crt|tls.key|ca.crt   per-identity bundles
#   csr/<node>.csr|<node>.key              node-side requests (key stays put)
set -euo pipefail

RECEPTOR_IMAGE="${RECEPTOR_IMAGE:-quay.io/ansible/receptor:v1.6.7@sha256:6296f6cd3b0301cc7c9376e48ae15a42fc7b606235d08e94543fe77661cea4d2}"
MESH_SECRETS="${MESH_SECRETS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/secrets/receptor}"
# Leaf lifetime 1y, CA 10y — override with env (RFC3339).
CA_NOT_AFTER="${CA_NOT_AFTER:-$(date -u -d "+3650 days" +%Y-%m-%dT%H:%M:%SZ)}"
CERT_NOT_AFTER="${CERT_NOT_AFTER:-$(date -u -d "+365 days" +%Y-%m-%dT%H:%M:%SZ)}"

die() { echo "ERROR: $*" >&2; exit 1; }

# Run receptor/openssl in the pinned image with $MESH_SECRETS mounted at /pki.
# Runs as root inside; files are chowned to the invoking user afterwards so the
# scripts work from any uid without leaving root-owned litter.
rimg() {
  docker run --rm -u 0:0 -v "$MESH_SECRETS:/pki" --entrypoint sh "$RECEPTOR_IMAGE" -euc "$1"
  docker run --rm -u 0:0 -v "$MESH_SECRETS:/pki" --entrypoint sh "$RECEPTOR_IMAGE" -euc \
    "chown -R $(id -u):$(id -g) /pki"
}

# Assert a PEM (cert or CSR) carries EXACTLY the given receptor node id in its
# SAN — the identity receptor enforces at connect time. Signing is gated on
# this so a CSR cannot smuggle a different identity past the CA.
assert_receptor_id() { # file-in-/pki  kind(x509|req)  expected-id
  rimg "openssl $2 -in /pki/$1 -text -noout \
        | grep -F 'othername: 1.3.6.1.4.1.2312.19.1:$3' >/dev/null \
        || { echo 'identity check failed: $1 does not carry receptor node id $3' >&2; exit 1; }"
}
