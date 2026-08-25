#!/bin/bash
# Work-command wrapper: keep the runner streaming protocol's stdout PURE.
#
# receptor merges the work command's stderr into the unit's stdout results, and
# ansible-runner's Processor hard-fails on the first non-JSON line it reads —
# so any library that greets stderr (OpenSSL's "Failed to activate fips
# provider" does, on every python start in this image) corrupts the stream and
# the controller-side `ansible-runner process` reports an error status with no
# events. Divert stderr to the node's log; stdout carries only protocol lines.
#
# The log is size-capped: truncated whenever it exceeds ~1 MiB, so it cannot
# grow without bound across jobs (concurrent workers append atomically via
# O_APPEND; the cap bounds size, it is not a rotation scheme).
log=/var/lib/receptor/worker-stderr.log
if [ -f "$log" ] && [ "$(stat -c %s "$log" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  : > "$log"
fi
exec ansible-runner worker "$@" 2>>"$log"
