#!/bin/bash
# EXECUTION-NODE side: generate a key and CSR for this node. The private key is
# created here and NEVER leaves — only the .csr travels to the CA host for
# node-sign.sh. Run with MESH_SECRETS pointed at the node's local secret store.
#   mesh/pki/node-csr.sh <node-id> [extra-dns-name ...]
. "$(dirname "$0")/common.sh"

ID="${1:?usage: node-csr.sh <node-id> [extra-dns-name ...]}"; shift || true
check_id "$ID"
for d in "$@"; do check_dns "$d"; done

rimg ID="$ID" EXTRA_DNS="$*" -- '
  mkdir -p /pki/csr && cd /pki/csr
  set -- dnsname="$ID"
  for d in $EXTRA_DNS; do set -- "$@" dnsname="$d"; done
  receptor --cert-makereq commonname="$ID" bits=2048 "$@" nodeid="$ID" \
    outreq="$ID.csr" outkey="$ID.key"
  chmod 600 "$ID.key" && chmod 644 "$ID.csr"'
echo "request: $MESH_SECRETS/csr/$ID.csr   (key stays here: $MESH_SECRETS/csr/$ID.key)"
echo "send ONLY the .csr to the CA host, then: mesh/pki/node-sign.sh csr/$ID.csr $ID${*:+ $*}"
