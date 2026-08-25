#!/bin/bash
# Create the mesh CA. Idempotent: refuses to touch an existing CA unless
# --force is given (re-keying the CA orphans every issued cert). ca.crt OR
# ca.key marks the CA as initialized — after the operator moves ca.key to
# offline storage (as instructed below), ca.crt alone must still arm the guard.
#   mesh/pki/mesh-ca-init.sh [--force] [common-name]
. "$(dirname "$0")/common.sh"

FORCE=0; CN="mesh-ca"
for a in "$@"; do case "$a" in --force) FORCE=1;; *) CN="$a";; esac; done
case "$CN" in ''|*[!A-Za-z0-9._' '-]*) die "common name '$CN' invalid: [A-Za-z0-9._ -]+";; esac

mkdir -p "$MESH_SECRETS/ca"
if { [ -e "$MESH_SECRETS/ca/ca.key" ] || [ -e "$MESH_SECRETS/ca/ca.crt" ]; } && [ "$FORCE" != 1 ]; then
  die "CA already exists at $MESH_SECRETS/ca — re-keying orphans every issued cert; pass --force only if that is intended"
fi

rimg CN="$CN" NOT_AFTER="$CA_NOT_AFTER" -- '
  mkdir -p /pki/ca && cd /pki/ca
  receptor --cert-init commonname="$CN" bits=3072 \
    outcert=ca.crt outkey=ca.key notafter="$NOT_AFTER"
  chmod 600 ca.key && chmod 644 ca.crt'
echo "CA created: $MESH_SECRETS/ca/ca.crt"
echo "IMPORTANT: move ca.key to OFFLINE storage — it must never reach a runtime container (plan §4)."
