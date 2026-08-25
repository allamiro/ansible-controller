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

# Assert a PEM (cert or CSR) carries EXACTLY ONE receptor node id — the given
# one — and no DNS name outside the allowlist. Presence alone is not enough:
# a CSR listing the authorised id PLUS a second identity would be signed with
# both, and a smuggled DNS name could let a node cert impersonate an ingress
# to its peers. Signing is gated on this.
#
# Values travel as environment variables into a single-quoted script — nothing
# from the arguments is interpolated into shell text on either side.
assert_receptor_id() { # file-in-/pki  kind(x509|req)  expected-id  [allowed-dns...]
  local f="$1" kind="$2" want="$3"; shift 3
  local allow="$want $*"
  docker run --rm -u 0:0 -v "$MESH_SECRETS:/pki" \
    -e F="$f" -e KIND="$kind" -e WANT="$want" -e ALLOW="$allow" \
    --entrypoint sh "$RECEPTOR_IMAGE" -eu -c '
      san=$(openssl "$KIND" -in "/pki/$F" -text -noout \
            | grep -A1 "Subject Alternative Name" | tail -1)
      ids=$(printf "%s\n" "$san" \
            | grep -o "othername: 1.3.6.1.4.1.2312.19.1:[^, ]*" \
            | sed "s/.*19\.1://")
      if [ "$ids" != "$WANT" ]; then
        echo "identity check failed: $F must carry exactly receptor node id \"$WANT\"; found: $(printf "%s" "$ids" | tr "\n" " ")" >&2
        exit 1
      fi
      dns=$(printf "%s\n" "$san" | grep -o "DNS:[^, ]*" | sed "s/^DNS://")
      for n in $dns; do
        ok=0
        for a in $ALLOW; do
          if [ "$n" = "$a" ]; then ok=1; fi
        done
        if [ "$ok" != 1 ]; then
          echo "identity check failed: $F carries unexpected DNS name \"$n\" (allowed: $ALLOW)" >&2
          exit 1
        fi
      done'
}
