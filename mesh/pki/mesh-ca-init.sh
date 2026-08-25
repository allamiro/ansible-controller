#!/bin/bash
# Create the mesh CA. Idempotent: refuses to touch an existing CA unless
# --force is given (re-keying the CA orphans every issued cert).
#   mesh/pki/mesh-ca-init.sh [--force] [common-name]
. "$(dirname "$0")/common.sh"

FORCE=0; CN="mesh-ca"
for a in "$@"; do case "$a" in --force) FORCE=1;; *) CN="$a";; esac; done

mkdir -p "$MESH_SECRETS/ca"
if [ -e "$MESH_SECRETS/ca/ca.key" ] && [ "$FORCE" != 1 ]; then
  die "CA already exists at $MESH_SECRETS/ca — re-keying orphans every issued cert; pass --force only if that is intended"
fi

rimg "mkdir -p /pki/ca && cd /pki/ca \
  && receptor --cert-init commonname='$CN' bits=3072 \
       outcert=ca.crt outkey=ca.key notafter=$CA_NOT_AFTER \
  && chmod 600 ca.key && chmod 644 ca.crt"
echo "CA created: $MESH_SECRETS/ca/ca.crt"
echo "IMPORTANT: move ca.key to OFFLINE storage — it must never reach a runtime container (plan §4)."
