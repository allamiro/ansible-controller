#!/bin/bash
# Shared plumbing for the mesh PKI scripts. Everything runs receptor's own
# cert tooling inside the digest-pinned receptor image, so the operator needs
# no local receptor install and every environment issues identical certs.
#
# SECURITY MODEL FOR INPUTS: no caller-supplied value is ever interpolated
# into shell text. Scripts passed to the container are single-quoted string
# constants; values travel exclusively as environment variables (rimg's
# NAME=value arguments). Inputs are ALSO validated against strict grammars —
# defense in depth, and it keeps file paths sane.
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
# Leaf lifetime 1y, CA 10y — override with env (RFC3339). GNU date first,
# BSD (macOS) date as fallback, so Docker Desktop hosts work too.
future_utc() { # days -> RFC3339
  date -u -d "+$1 days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -v "+${1}d" +%Y-%m-%dT%H:%M:%SZ
}
CA_NOT_AFTER="${CA_NOT_AFTER:-$(future_utc 3650)}"
CERT_NOT_AFTER="${CERT_NOT_AFTER:-$(future_utc 365)}"

die() { echo "ERROR: $*" >&2; exit 1; }

# Input grammars. IDs additionally refuse the path components '.' and '..',
# which the character set alone would admit and which escape issued/<id>/.
check_id()   { case "$1" in ''|.|..|*[!A-Za-z0-9._-]*) die "node id '$1' invalid: [A-Za-z0-9._-]+, not '.'/'..'";; esac; }
check_dns()  { case "$1" in ''|-*|*[!A-Za-z0-9.-]*) die "DNS name '$1' invalid: [A-Za-z0-9.-]+, no leading '-'";; esac; }
check_rfc3339() {
  [[ "$1" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](Z|[+-][0-9]{2}:[0-9]{2})$ ]] \
    || die "'$1' is not RFC3339 (expected e.g. 2027-01-01T00:00:00Z)"
}
check_relpath() {
  case "$1" in ''|/*|*[!A-Za-z0-9._/-]*) die "path '$1' invalid: relative, [A-Za-z0-9._/-]+";; esac
  case "/$1/" in */../*|*/./*) die "path '$1' invalid: no '.' or '..' components";; esac
}
check_id_list() { local d; for d in $1; do check_id "$d"; done; }

check_rfc3339 "$CA_NOT_AFTER"
check_rfc3339 "$CERT_NOT_AFTER"

# rimg [NAME=value ...] -- 'single-quoted script'
# Runs the script in the pinned image with $MESH_SECRETS at /pki. Values reach
# the script only through the environment. Files are chowned back to the
# invoking user so the scripts work from any uid without root-owned litter.
rimg() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=( -e "$1" ); shift; done
  [ "${1:-}" = "--" ] || die "rimg usage: rimg [NAME=value ...] -- script"
  shift
  docker run --rm -u 0:0 "${envs[@]}" -v "$MESH_SECRETS:/pki" \
    --entrypoint sh "$RECEPTOR_IMAGE" -eu -c "$1"
  docker run --rm -u 0:0 -e OWNER="$(id -u):$(id -g)" -v "$MESH_SECRETS:/pki" \
    --entrypoint sh "$RECEPTOR_IMAGE" -eu -c 'chown -R "$OWNER" /pki'
}

# Assert a PEM (cert or CSR) carries EXACTLY ONE receptor node id — the given
# one — and no DNS name outside the allowlist. Presence alone is not enough:
# a CSR listing the authorised id PLUS a second identity would be signed with
# both, and a smuggled DNS name could let a node cert impersonate an ingress.
#
# The SAN block is collected in full (every continuation line until the next
# extension header), and the otherName separator matches one or more colons —
# robust against openssl render variations across versions.
assert_receptor_id() { # file-in-/pki  kind(x509|req)  expected-id  [allowed-dns...]
  local f="$1" kind="$2" want="$3"; shift 3
  check_relpath "$f"
  rimg F="$f" KIND="$kind" WANT="$want" ALLOW="$want $*" -- '
    san=$(openssl "$KIND" -in "/pki/$F" -text -noout \
          | awk "/Subject Alternative Name/{f=1;next}
                 f && /^[[:space:]]*(X509v3|Netscape|Authority|Signature|Attributes|Requested Extensions|Exponent|Modulus)/ {exit}
                 f {print}")
    ids=$(printf "%s\n" "$san" \
          | grep -o "othername: 1.3.6.1.4.1.2312.19.1:*[^, ]*" \
          | sed "s/.*19\.1:*://;s/^://")
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
