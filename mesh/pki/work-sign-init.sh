#!/bin/bash
# Create the mesh WORK-SIGNING keypair (mesh plan Phase 9) — the key the
# control plane uses to sign every work submission, and the public key every
# execution node uses to verify one before running it. Together with mTLS
# this splits authority: a node's certificate admits it to the mesh, but only
# the control plane can SUBMIT work (plan UC6 — a third-party node executes,
# it cannot inject).
#
# Offline like the CA: the private key is issued here and travels only to the
# control host's ingress sidecars; nodes ever receive only work-public.pem.
#
# Uses the CA host's own openssl (unlike the cert scripts, receptor's image
# ships no RSA-to-SPKI extraction tooling): openssl is preinstalled on
# effectively every Linux/macOS host; the README lists it as a CA-host
# prerequisite.
#
# Idempotent: refuses an existing keypair unless --force is given (re-keying
# orphans every node's verification copy until the new public key is rolled
# out to all of them).
#   mesh/pki/work-sign-init.sh [--force]
. "$(dirname "$0")/common.sh"

command -v openssl >/dev/null 2>&1 \
  || die "openssl is required on the CA host for the work-signing keypair"

FORCE=0
[ "${1:-}" = --force ] && FORCE=1

SIGN_DIR="$MESH_SECRETS/work-signing"
PRIV="$SIGN_DIR/work-private.pem"
PUB="$SIGN_DIR/work-public.pem"

if [ "$FORCE" != 1 ] && { [ -e "$PRIV" ] || [ -e "$PUB" ]; }; then
  die "work-signing keypair already exists under $SIGN_DIR — re-keying orphans \
every node's verification copy; pass --force only if you will roll the new \
public key to every node"
fi

(umask 077 && mkdir -p "$SIGN_DIR")
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$PRIV" 2>/dev/null
openssl pkey -in "$PRIV" -pubout -out "$PUB" 2>/dev/null
chmod 600 "$PRIV"
chmod 644 "$PUB"

echo "work-signing keypair created:"
echo "  private: $PRIV   (control host's ingress sidecars ONLY — never a node)"
echo "  public:  $PUB    (distribute to every execution node)"
