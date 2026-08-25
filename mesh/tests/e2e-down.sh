#!/bin/bash
# Tear down the e2e environment, including its volumes (disposable SSH keypair).
set -euo pipefail
cd "$(dirname "$0")/../.."
# The packaged node from check 26 sits on the suite's networks; it must go
# first or `down` cannot remove them ("network has active endpoints").
docker rm -f mesh-node-exec-e2e-b >/dev/null 2>&1 || true
docker compose -f mesh/tests/e2e.compose.yml down -v
