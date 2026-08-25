#!/bin/bash
# Execution-node entrypoint: render the receptor node config from env, then exec
# receptor as PID 1 (unprivileged — the image sets USER ansible).
#
#   RECEPTOR_NODE_ID     required  stable mesh identity, e.g. exec-net20-a.
#                                  Phase 6 ties this to the node's mTLS cert
#                                  identity, so treat it as permanent.
#   RECEPTOR_PEERS       required  comma-separated ingress list, e.g.
#                                  "receptor-controller:27199". A LIST from day
#                                  one (mesh plan §4): Tier 1 ingress redundancy
#                                  is then just a second address, not a rewrite.
#   RECEPTOR_LOG_LEVEL   optional  debug|info|warning|error (default info)
#
#   RECEPTOR_TLS_CERT    \
#   RECEPTOR_TLS_KEY      } paths to this node's cert, key, and the mesh CA.
#   RECEPTOR_TLS_CA      /  ALL THREE are required: as of Phase 6 the mesh is
#                           mTLS-only and this entrypoint refuses to start
#                           without them rather than fall back to plaintext.
#   RECEPTOR_INSECURE_DEV   set to 1 to run WITHOUT TLS — exists solely for
#                           throwaway wiring experiments; never set in any
#                           production or e2e file, and the node says so
#                           loudly at startup when used.
#
# The config is rendered fresh on every start — a stale copy is always
# overwritten, and nothing about the mesh topology is baked into the image. The
# compose files additionally mount /run/receptor as tmpfs so the rendered
# config and the control socket never touch the container's writable layer.
#
# SECURITY: mTLS is mandatory (Phase 6). The work-command still accepts
# unsigned work until Phase 9 adds work signing.
set -euo pipefail

: "${RECEPTOR_NODE_ID:?RECEPTOR_NODE_ID is required (e.g. exec-net20-a)}"
: "${RECEPTOR_PEERS:?RECEPTOR_PEERS is required (comma-separated host:port list)}"
RECEPTOR_LOG_LEVEL="${RECEPTOR_LOG_LEVEL:-info}"

# Validate BEFORE rendering: these values are interpolated into YAML, so a value
# carrying a newline or YAML syntax could inject additional receptor actions
# into the config. Reject anything outside a strict character set instead of
# trusting the environment.
case "$RECEPTOR_NODE_ID" in
  *[!A-Za-z0-9._-]*|'')
    echo "ERROR: RECEPTOR_NODE_ID '$RECEPTOR_NODE_ID' invalid: [A-Za-z0-9._-]+ only" >&2; exit 1;;
esac
case "$RECEPTOR_LOG_LEVEL" in
  debug|info|warning|error) ;;
  *) echo "ERROR: RECEPTOR_LOG_LEVEL '$RECEPTOR_LOG_LEVEL' invalid: debug|info|warning|error" >&2; exit 1;;
esac

TLS=1
if [ "${RECEPTOR_INSECURE_DEV:-0}" = 1 ]; then
  TLS=0
  echo "WARNING: RECEPTOR_INSECURE_DEV=1 — this node peers in PLAINTEXT with no authentication." >&2
  echo "WARNING: acceptable only for throwaway wiring experiments; never in production." >&2
else
  for v in RECEPTOR_TLS_CERT RECEPTOR_TLS_KEY RECEPTOR_TLS_CA; do
    [ -n "${!v:-}" ] || { echo "ERROR: $v is required — the mesh is mTLS-only (set RECEPTOR_INSECURE_DEV=1 only for throwaway experiments)" >&2; exit 1; }
    [ -f "${!v}" ]   || { echo "ERROR: $v '${!v}' not found" >&2; exit 1; }
  done
fi

conf=/run/receptor/receptor.conf

# receptor 1.6.x parses a YAML LIST of single-key action maps; the mapping
# ("version: 2") style is rejected by this release. See mesh/config/receptor/.
{
  printf -- '---\n'
  printf -- '- node:\n    id: %s\n' "${RECEPTOR_NODE_ID}"
  printf -- '- log-level:\n    level: %s\n' "${RECEPTOR_LOG_LEVEL}"

  # Local control socket: owner-only, used by the HEALTHCHECK (receptorctl
  # status) and for on-node debugging. Never a TCP control listener.
  printf -- '- control-service:\n    service: control\n    filename: /run/receptor/receptor.sock\n    permissions: 0600\n'

  # Mutual TLS client identity. rootcas pins the mesh CA; insecureskipverify
  # and skipreceptornamescheck are deliberately NEVER emitted (§9.3) — the
  # server must present a CA-signed cert carrying ITS node id, and this node
  # presents its own for the server's requireclientcert.
  if [ "$TLS" = 1 ]; then
    printf -- '- tls-client:\n    name: mesh-tls\n    cert: %s\n    key: %s\n    rootcas: %s\n' \
      "$RECEPTOR_TLS_CERT" "$RECEPTOR_TLS_KEY" "$RECEPTOR_TLS_CA"
  fi

  # Dial OUT to every ingress; redial forever. The node never listens for
  # backend connections — net-mapped zones stay unreachable from outside.
  # Each peer is validated host:port (same injection concern as above), and at
  # least one must survive trimming — a peers value of only commas/whitespace
  # would otherwise start a node connected to nothing, silently.
  peer_count=0
  IFS=',' read -ra peers <<< "${RECEPTOR_PEERS}"
  for peer in "${peers[@]}"; do
    peer="${peer//[[:space:]]/}"
    [ -n "$peer" ] || continue
    case "$peer" in
      *:*) ;;
      *) echo "ERROR: peer '$peer' invalid: missing :port" >&2; exit 1;;
    esac
    host="${peer%:*}"; port="${peer##*:}"
    case "$host" in *[!A-Za-z0-9._-]*|'') host= ;; esac
    case "$port" in *[!0-9]*|'') port= ;; esac
    if [ -z "$host" ] || [ -z "$port" ]; then
      echo "ERROR: peer '$peer' invalid: expected host:port (host [A-Za-z0-9._-]+, numeric port)" >&2
      exit 1
    fi
    if [ "$TLS" = 1 ]; then
      printf -- '- tcp-peer:\n    address: %s\n    redial: true\n    tls: mesh-tls\n' "$peer"
    else
      printf -- '- tcp-peer:\n    address: %s\n    redial: true\n' "$peer"
    fi
    peer_count=$((peer_count + 1))
  done
  if [ "$peer_count" -eq 0 ]; then
    echo "ERROR: RECEPTOR_PEERS '${RECEPTOR_PEERS}' contains no usable host:port entries" >&2
    exit 1
  fi

  # The unit of work this node accepts: an ansible-runner worker fed a streamed
  # private data dir (transmit -> work submit). mesh-worker wraps the runner to
  # keep stderr OUT of the results stream: receptor merges the command's stderr
  # into the unit stdout, and a single non-JSON line (OpenSSL greets stderr on
  # every python start here) breaks the controller-side Processor at its first
  # read. allowruntimeparams lets the submitter pass runner args;
  # verifysignature flips on in Phase 9.
  printf -- '- work-command:\n    worktype: ansible-runner\n    command: /usr/local/bin/mesh-worker\n    allowruntimeparams: true\n'
} > "$conf"

exec receptor -c "$conf"
