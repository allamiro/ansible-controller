#!/bin/bash
# Work-command wrapper: keep the runner streaming protocol's stdout PURE.
#
# receptor merges the work command's stderr into the unit's stdout results, and
# ansible-runner's Processor hard-fails on the first non-JSON line it reads —
# so any library that greets stderr (OpenSSL's "Failed to activate fips
# provider" does, on every python start in this image) corrupts the stream and
# the controller-side `ansible-runner process` reports an error status with no
# events.
#
# Ordering is load-bearing: stderr is diverted BEFORE any other command runs,
# because anything a prior command printed to stderr (a failed stat, an mv
# race message) would itself land in the results stream — the exact corruption
# this wrapper exists to prevent.
#
# Each worker writes its own log — no shared file, so concurrent workers have
# nothing to race over and no rotation can yank an inode out from under a
# writer. `tail -c 1M` keeps the LAST 1 MiB (where a failing job's traceback
# lives), consuming the whole stream so the worker is never EPIPE-killed.
# After diversion, logs beyond the newest 16 are pruned — a strict disk bound
# of ≤16 MiB retained plus ≤1 MiB per concurrently running worker — and any
# noise the pruning itself makes lands in this worker's own log, not the
# stream.
log="/var/lib/receptor/worker-$$-$(date +%s).log"
exec 2> >(tail -c 1048576 > "$log")

ls -t /var/lib/receptor/worker-*.log 2>/dev/null | tail -n +17 | xargs -r rm -f --

exec ansible-runner worker "$@"
