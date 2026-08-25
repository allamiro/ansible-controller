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

# Exactly [--force]: a typo must not silently mint credentials.
FORCE=0
case "$#:${1:-}" in
  0:) ;;
  1:--force) FORCE=1 ;;
  *) die "usage: work-sign-init.sh [--force]" ;;
esac

SIGN_DIR="$MESH_SECRETS/work-signing"
PRIV="$SIGN_DIR/work-private.pem"
PUB="$SIGN_DIR/work-public.pem"

(umask 077 && mkdir -p "$SIGN_DIR")
# One rotation at a time: the recovery logic below reasons about the pair's
# on-disk state, which a concurrent run would invalidate. mkdir is the
# portable atomic lock — macOS ships no flock CLI, and the CA flow
# explicitly supports macOS hosts (see common.sh's BSD date fallback).
LOCK_DIR="$SIGN_DIR/.rotation.lock"
mkdir "$LOCK_DIR" 2>/dev/null \
  || die "another work-sign-init appears to be running (remove $LOCK_DIR if it is stale)"
cleanup() { rm -rf "$LOCK_DIR"; [ -n "${TMP:-}" ] && rm -rf "$TMP"; }
trap cleanup EXIT

# The guard is a VALIDITY check, not an existence check, and that is what
# makes rotation recoverable: two files cannot be replaced atomically as a
# unit, so a crash between the renames can strand a mixed pair — which the
# next run detects (derived public != stored public) and simply regenerates,
# because a mismatched pair is already broken for every consumer. Only a
# CONSISTENT pair is protected behind --force.
pair_state() {
  { [ -e "$PRIV" ] || [ -e "$PUB" ]; } || { echo absent; return; }
  { [ -f "$PRIV" ] && [ -f "$PUB" ]; } || { echo broken; return; }
  local derived
  derived=$(openssl pkey -in "$PRIV" -pubout 2>/dev/null) || { echo broken; return; }
  [ "$derived" = "$(cat "$PUB")" ] && echo ok || echo broken
}
case "$(pair_state)" in
  ok)
    if [ "$FORCE" != 1 ]; then
      die "a consistent work-signing keypair already exists under $SIGN_DIR — \
re-keying orphans every node's verification copy; pass --force only if you \
will roll the new public key to every node"
    fi
    echo "WARNING: --force re-keys the work-signing pair. Every node keeps the OLD" >&2
    echo "WARNING: public key and will refuse ALL work until you roll the new one out." >&2
    ;;
  broken)
    echo "WARNING: found an inconsistent/partial keypair (interrupted rotation?) — regenerating." >&2
    ;;
esac

# Both halves are generated into a private staging dir and published only
# after both commands succeeded; the private key is published FIRST so an
# interruption between the renames leaves priv-new/pub-old — a mismatch the
# validity guard above recovers on the next run.
TMP=$(umask 077 && mktemp -d "$SIGN_DIR/.new.XXXXXX")
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$TMP/work-private.pem" 2>/dev/null \
  || die "openssl genpkey failed"
openssl pkey -in "$TMP/work-private.pem" -pubout -out "$TMP/work-public.pem" 2>/dev/null \
  || die "public-key extraction failed"
chmod 600 "$TMP/work-private.pem"
chmod 644 "$TMP/work-public.pem"
mv "$TMP/work-private.pem" "$PRIV"
mv "$TMP/work-public.pem" "$PUB"

echo "work-signing keypair created:"
echo "  private: $PRIV   (control host's ingress sidecars ONLY — never a node)"
echo "  public:  $PUB    (distribute to every execution node)"
