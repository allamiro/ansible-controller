#!/bin/bash
# Work-command wrapper: keep the runner streaming protocol's stdout PURE.
#
# receptor merges the work command's stderr into the unit's stdout results, and
# ansible-runner's Processor hard-fails on the first non-JSON line it reads —
# so any library that greets stderr (OpenSSL's "Failed to activate fips
# provider" does, on every python start in this image) corrupts the stream and
# the controller-side `ansible-runner process` reports an error status with no
# events. Divert stderr to the node's log; stdout carries only protocol lines.
exec ansible-runner worker "$@" 2>>/var/lib/receptor/worker-stderr.log
