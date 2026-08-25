#!/bin/bash
# Tear down the e2e environment, including its volumes (disposable SSH keypair).
set -euo pipefail
cd "$(dirname "$0")/../.."
# Anything still attached to the suite's networks that is not the suite's own
# — the packaged node check 26 starts from mesh/compose.node.yml, a rogue an
# interrupted negative check left behind — must go first, or `down` fails with
# "network has active endpoints". Found by network membership rather than by
# name, so a renamed identity cannot silently reintroduce that failure.
proj="${COMPOSE_PROJECT_NAME:-mesh-e2e}"
for c in $(docker ps -aq --filter "network=${proj}_ctlnet" --filter "network=${proj}_targetnet" 2>/dev/null); do
  [ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null)" = "$proj" ] \
    || docker rm -f "$c" >/dev/null 2>&1 || true
done
docker compose -f mesh/tests/e2e.compose.yml down -v
