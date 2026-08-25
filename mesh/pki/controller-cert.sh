#!/bin/bash
# Issue a CONTROL-PLANE identity (sidecar ingress) in one step — key and cert
# are both born where the CA lives, which is correct only for the control host.
# Execution nodes use node-csr.sh + node-sign.sh so their keys never move.
#   mesh/pki/controller-cert.sh <node-id> [extra-dns-name ...]
. "$(dirname "$0")/common.sh"

ID="${1:?usage: controller-cert.sh <node-id> [extra-dns-name ...]}"; shift || true
check_id "$ID"
for d in "$@"; do check_dns "$d"; done
[ -f "$MESH_SECRETS/ca/ca.key" ] || die "no CA key at $MESH_SECRETS/ca — run mesh-ca-init.sh (or restore the offline key to sign)"

rimg ID="$ID" EXTRA_DNS="$*" NOT_AFTER="$CERT_NOT_AFTER" -- '
  mkdir -p "/pki/issued/$ID" && cd "/pki/issued/$ID"
  set -- dnsname="$ID"
  for d in $EXTRA_DNS; do set -- "$@" dnsname="$d"; done
  receptor --cert-makereq commonname="$ID" bits=2048 "$@" nodeid="$ID" \
    outreq=tls.csr outkey=tls.key
  receptor --cert-signreq req=tls.csr cacert=/pki/ca/ca.crt cakey=/pki/ca/ca.key \
    outcert=tls.crt verify=yes notafter="$NOT_AFTER"
  cp /pki/ca/ca.crt ca.crt && rm -f tls.csr
  chmod 600 tls.key && chmod 644 tls.crt ca.crt'
assert_receptor_id "issued/$ID/tls.crt" x509 "$ID" "$@"
echo "issued: $MESH_SECRETS/issued/$ID/{tls.crt,tls.key,ca.crt}"
