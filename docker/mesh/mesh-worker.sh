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
# The log is bounded in BOTH dimensions and keeps the part that matters. Across
# jobs: truncated at start when over ~1 MiB. Within a job: stderr flows through
# `tail -c 1M`, a rolling window that consumes the whole stream (no EPIPE risk,
# memory bounded at the window size) and appends the LAST 1 MiB when the worker
# exits — the tail is where a failing job's traceback lives, unlike a head
# capture that would keep startup noise and drop the error. Worst case on disk
# ≈ 1 MiB + (concurrent workers × 1 MiB); it cannot fill the disk.
# Rotation instead of a size threshold: each worker moves the current log to
# .1 (keeping the previous worker's tail for comparison) and appends its own
# window to a fresh file. The on-disk bound is strict — ≤ 1 MiB in .1 plus
# ≤ 1 MiB per concurrently running worker — with no threshold edge to leak
# past (a -gt check let an exactly-1MiB log survive and grow by appends).
log=/var/lib/receptor/worker-stderr.log
[ -f "$log" ] && mv -f "$log" "$log.1"
exec 2> >(tail -c 1048576 >> "$log")
exec ansible-runner worker "$@"
