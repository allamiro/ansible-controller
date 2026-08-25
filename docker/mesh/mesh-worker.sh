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
# The log is bounded in BOTH dimensions. Across jobs: truncated at start when it
# exceeds ~1 MiB. Within a job: stderr flows through a sink that copies at most
# 1 MiB and then drains the rest to /dev/null — dd stops at the cap but cat
# keeps the pipe open, so a chatty worker is never killed by EPIPE on stderr.
# Worst case ≈ 1 MiB + (concurrent workers × 1 MiB); it cannot fill the disk.
log=/var/lib/receptor/worker-stderr.log
if [ -f "$log" ] && [ "$(stat -c %s "$log" 2>/dev/null || echo 0)" -gt 1048576 ]; then
  : > "$log"
fi
exec 2> >(dd bs=1024 count=1024 of="$log" oflag=append conv=notrunc status=none 2>/dev/null; cat > /dev/null)
exec ansible-runner worker "$@"
