#!/bin/bash
# Every check the Ansible content gate applies, in one place, so the workflow
# and the documented local reproduction cannot drift apart.
#
# Run this INSIDE the controller image: the toolchain, the baked Galaxy
# collections (ansible.posix, community.general) and the controller's own
# ansible.cfg are then the ones operators actually execute with, rather than a
# separately pinned approximation of them.
set -euo pipefail
cd "$(dirname "$0")/../.."

# The controller runs with ./configs at /configs and ./playbooks at
# /configs/playbooks (docker-compose.yml), and its ansible.cfg names those
# absolute paths in roles_path and collections_path. Reproduce that layout
# inside the container rather than bind-mounting it: Docker cannot create the
# nested /configs/playbooks mountpoint inside a read-only /configs mount, and a
# writable copy also gives the fact cache somewhere to live. An existing
# /configs — a real controller container — is used as it stands, never replaced.
if [ ! -f /configs/ansible.cfg ]; then
  mkdir -p /configs
  cp -a configs/. /configs/
  cp -a playbooks /configs/playbooks
  # configs/.galaxy is host-persisted, gitignored runtime state: on a developer's
  # machine it holds whatever the controller has ever installed. It is first in
  # the configured collections_path, and installing the current requirements does
  # not remove content no longer declared — so carrying it in would let a stale or
  # undeclared dependency resolve locally while a clean CI checkout fails. Start
  # from nothing and install only what configs/requirements.yml declares. The
  # fact and inventory caches go for the same reason: they are not configuration.
  rm -rf /configs/.galaxy /configs/.facts_cache /configs/.inventory_cache
fi
export ANSIBLE_CONFIG="${ANSIBLE_CONFIG:-/configs/ansible.cfg}"

CONTENT=(playbooks/ gitlab/project-template/ mesh/labs/gitlab/project-seed/)
PLAYS=(playbooks/ mesh/labs/gitlab/project-seed/playbooks/ gitlab/project-template/playbooks/)

say() { printf '\n==> %s\n' "$*"; }

say "toolchain in use"
ansible --version | head -1
ansible-lint --version | head -1
echo "yamllint $(yamllint --version | awk '{print $2}')"
echo "collections: $(ansible-galaxy collection list 2>/dev/null | grep -cE '^[a-z0-9_]+\.[a-z0-9_]+' || echo 0) installed"

# Content declared in configs/requirements.yml is not baked into the image, so
# a playbook may depend on it. Empty lists are the shipped default and install
# nothing; a declared entry must resolve here as it would on the controller.
if python3 -c "import sys,yaml; d=yaml.safe_load(open('configs/requirements.yml')) or {}; sys.exit(0 if (d.get('roles') or d.get('collections')) else 1)"; then
  say "installing declared Galaxy content"
  # The same two commands and destinations docker/entrypoint.sh uses. A plain
  # `ansible-galaxy install -r` does install collections, but into
  # ~/.ansible/collections, which ansible.cfg's collections_path
  # (/configs/.galaxy/collections:/usr/share/ansible/collections) does not
  # search — so declared content would be present and still unresolvable.
  mkdir -p /configs/.galaxy
  ansible-galaxy role install -r configs/requirements.yml \
    --roles-path /configs/.galaxy/roles
  ansible-galaxy collection install -r configs/requirements.yml \
    -p /configs/.galaxy/collections
else
  say "configs/requirements.yml declares no extra Galaxy content"
fi

say "yamllint"
yamllint -c .yamllint "${CONTENT[@]}"

say "ansible-lint (production profile)"
ansible-lint "${PLAYS[@]}"

say "syntax-check, each playbook against its own inventory"
check() { printf '  %-56s' "$1"; ansible-playbook --syntax-check -i "$2" "$1" >/dev/null; echo ok; }
check playbooks/site.yml configs/inventory/hosts.ini
check playbooks/ping.yml configs/inventory/hosts.ini
check mesh/labs/gitlab/project-seed/playbooks/site.yml mesh/labs/gitlab/project-seed/inventory/lab.ini
check mesh/labs/gitlab/project-seed/playbooks/ping.yml mesh/labs/gitlab/project-seed/inventory/lab.ini
check gitlab/project-template/playbooks/site.yml gitlab/project-template/inventory/validation/hosts.ini

say "project template unit tests"
python3 -m unittest discover -s gitlab/project-template/tests

say "all Ansible content checks passed"
