#!/bin/bash
# CA side: sign a node's CSR — but only after proving the CSR carries EXACTLY
# the receptor node id being authorised. A CSR smuggling a different identity
# (the impersonation path mTLS exists to block) is refused before signing.
# Extra DNS names the node legitimately requested (matching node-csr.sh args)
# must be repeated here, or the CSR is refused — the CA decides what names it
# signs, never the requester alone.
#   mesh/pki/node-sign.sh <csr-path-relative-to-MESH_SECRETS> <node-id> [allowed-dns ...]
. "$(dirname "$0")/common.sh"

CSR="${1:?usage: node-sign.sh <csr-rel-path> <node-id> [allowed-dns ...]}"
ID="${2:?usage: node-sign.sh <csr-rel-path> <node-id> [allowed-dns ...]}"
case "$ID" in *[!A-Za-z0-9._-]*) die "node id '$ID' invalid";; esac
[ -f "$MESH_SECRETS/$CSR" ] || die "CSR '$MESH_SECRETS/$CSR' not found"
[ -f "$MESH_SECRETS/ca/ca.key" ] || die "no CA at $MESH_SECRETS/ca — run mesh-ca-init.sh first"

shift 2 || true
assert_receptor_id "$CSR" req "$ID" "$@"
rimg "mkdir -p /pki/issued/$ID \
  && receptor --cert-signreq req=/pki/$CSR cacert=/pki/ca/ca.crt cakey=/pki/ca/ca.key \
       outcert=/pki/issued/$ID/tls.crt verify=yes notafter=$CERT_NOT_AFTER \
  && cp /pki/ca/ca.crt /pki/issued/$ID/ca.crt \
  && chmod 644 /pki/issued/$ID/tls.crt /pki/issued/$ID/ca.crt"
assert_receptor_id "issued/$ID/tls.crt" x509 "$ID" "$@"
echo "signed: $MESH_SECRETS/issued/$ID/tls.crt (+ca.crt) — return these to the node; its key never moved"
