#!/bin/bash
# Run and export over the same forced-command SSH key. No SCP, shell access,
# mesh PKI, controller state mount, or Docker socket is granted to this job.
set -euo pipefail
umask 077
rm -rf mesh-artifacts
mkdir mesh-artifacts
channel=(ssh -i "$CTL_SSH_KEY" -o "UserKnownHostsFile=$CTL_KNOWN_HOSTS"
  -o StrictHostKeyChecking=yes -o BatchMode=yes "ansible@${CTL_HOST:-ctl.lab.local}")
rc=0
"${channel[@]}" ctl-run "$@" || rc=$?
# Never let a failed export turn a failed playbook into success. Conversely,
# missing required artifacts make an otherwise successful CI job fail visibly.
archive=$(mktemp)
trap 'rm -f "$archive"' EXIT
artifact_rc=0
if "${channel[@]}" ctl-run --artifacts "$@" > "$archive"; then
  tar -xf "$archive" -C mesh-artifacts || artifact_rc=$?
else
  artifact_rc=$?
fi
if [ "$artifact_rc" -ne 0 ]; then
  echo "ctl-ci: artifact transfer failed; original execution rc=$rc. Retry uses the same request; it does not dispatch again." >&2
fi
[ "$rc" -eq 0 ] || exit "$rc"
[ "$artifact_rc" -eq 0 ] || exit 2
