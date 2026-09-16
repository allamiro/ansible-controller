#!/bin/sh
# Informational only: never read input, open a browser, contact a service, or
# inspect inventory. Even explicit invocations stay silent in automation.
[ -t 0 ] && [ -t 1 ] && [ -t 2 ] || exit 0
[ -z "${CI:-}${GITHUB_ACTIONS:-}${GITLAB_CI:-}${TF_BUILD:-}${JENKINS_URL:-}${BUILDKITE:-}${CIRCLECI:-}${TEAMCITY_VERSION:-}" ] || exit 0
[ "${ANSIBLE_CONTROLLER_SUPPORT_NOTICE:-1}" != 0 ] || exit 0
if [ -n "${HOME:-}" ] && [ -e "$HOME/.hushlogin" ]; then exit 0; fi

printf '%s\n' \
  '' \
  'Ansible Controller mesh — optional support' \
  '  Learn more: mesh deployment assistance and support enquiries' \
  '    https://github.com/allamiro/ansible-controller/blob/main/SUPPORT.md' \
  '  Sponsor: https://github.com/sponsors/allamiro' \
  '    or https://buymeacoffee.com/pcileky2q' \
  '  Continue free: no action needed. No host limit or purchase requirement.' \
  '  Hide this notice: export ANSIBLE_CONTROLLER_SUPPORT_NOTICE=0' \
  '' >&2
exit 0
