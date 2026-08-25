#!/bin/bash
# Tear down the e2e environment, including its volumes (disposable SSH keypair).
set -euo pipefail
cd "$(dirname "$0")/../.."
docker compose -f mesh/tests/e2e.compose.yml down -v
