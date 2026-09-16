#!/bin/bash
set -euo pipefail
# Remove stale reports before dispatch. Never turn a failed execution into green.
rm -rf reports
phase=execute
for arg in "$@"; do
  case "$arg" in --sync-only) phase=sync;; --collect) phase=collect;; esac
done
rc=0
bash scripts/ctl-ci.sh "$@" || rc=$?
report_rc=0
python3 scripts/report.py "$rc" "$phase" || report_rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
[ "$report_rc" -eq 0 ] || exit 2
