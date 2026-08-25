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
# The config is rendered fresh on every start and lives on tmpfs-backed /run —
# nothing about the mesh topology is baked into the image or persists in the
# container filesystem.
#
# SECURITY (dev only until Phase 6): the tcp-peer below is plaintext and the
# work-command accepts unsigned work. Phase 6 makes mTLS mandatory and Phase 9
# adds work signing; this entrypoint will then refuse to start without TLS
# material rather than fall back to plaintext.
set -euo pipefail

: "${RECEPTOR_NODE_ID:?RECEPTOR_NODE_ID is required (e.g. exec-net20-a)}"
: "${RECEPTOR_PEERS:?RECEPTOR_PEERS is required (comma-separated host:port list)}"
RECEPTOR_LOG_LEVEL="${RECEPTOR_LOG_LEVEL:-info}"

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

  # Dial OUT to every ingress; redial forever. The node never listens for
  # backend connections — net-mapped zones stay unreachable from outside.
  IFS=',' read -ra peers <<< "${RECEPTOR_PEERS}"
  for peer in "${peers[@]}"; do
    peer="${peer//[[:space:]]/}"
    [ -n "$peer" ] || continue
    printf -- '- tcp-peer:\n    address: %s\n    redial: true\n' "$peer"
  done

  # The unit of work this node accepts: an ansible-runner worker fed a streamed
  # private data dir (transmit -> work submit). allowruntimeparams lets the
  # submitter pass runner args; verifysignature flips on in Phase 9.
  printf -- '- work-command:\n    worktype: ansible-runner\n    command: ansible-runner\n    params: worker\n    allowruntimeparams: true\n'
} > "$conf"

exec receptor -c "$conf"
