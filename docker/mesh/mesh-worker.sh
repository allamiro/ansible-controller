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
# ${EPOCHSECONDS} is a bash builtin: no subprocess runs before the diversion,
# so nothing (not even a failing date) can print to the undiverted stderr. The
# sink itself is also failure-proof: tail's own errors are discarded and a cat
# fallback keeps consuming, so an unopenable log file can neither corrupt the
# stream nor EPIPE-kill the worker.
log="/var/lib/receptor/worker-$$-${EPOCHSECONDS}.log"
exec 2> >(tail -c 1048576 2>/dev/null > "$log" || cat > /dev/null 2>&1)

# Keep the newest 15 PRIOR logs: the sink above runs asynchronously, so this
# worker's own file may or may not exist yet when the prune runs. Counting
# only survivors-that-are-not-us makes the bound exact either way — at most
# 15 prior + this worker's = 16 retained, ≤1 MiB each.
ls -t /var/lib/receptor/worker-*.log 2>/dev/null | grep -Fxv "$log" | tail -n +16 | xargs -r rm -f --

# NOT exec: the worker owns credential cleanup (mesh plan Phase 7). The
# transmitted PDD can carry env/ssh_key, and the unit directory persists on
# this node until the controller releases it — which never happens when a
# submit went ambiguous or the results stream broke. Destroying the key right
# after execution makes cleanup independent of controller connectivity; the
# eventual release then removes an already-credential-free unit dir. receptor
# runs this command inside the unit dir, so the search is scoped to it. Every
# step is failure-proof: cleanup must never rewrite the runner's exit code.
rc=0
ansible-runner worker "$@" || rc=$?
find . -type f -path '*/env/ssh_key' -exec shred -u -- {} \; 2>/dev/null \
  || find . -type f -path '*/env/ssh_key' -exec rm -f -- {} \; 2>/dev/null \
  || true
exit "$rc"
