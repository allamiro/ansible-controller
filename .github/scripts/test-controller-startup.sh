#!/bin/bash
# Disposable loopback-only startup/SSH tests. Never contact managed hosts.
set -euo pipefail
image=${1:?controller image required}
fixture=$(mktemp -d)
container=""
cleanup() {
  [ -z "$container" ] || docker rm -f "$container" >/dev/null 2>&1 || true
  rm -rf "$fixture"
}
trap cleanup EXIT
mkdir -p "$fixture/default" "$fixture/site" "$fixture/deps"
for pair in 'default 33' 'site 77'; do
  read -r directory forks <<< "$pair"
  printf '[defaults]\nforks = %s\nhost_key_checking = True\n' "$forks" > "$fixture/$directory/ansible.cfg"
done
touch "$fixture/default/pip-requirements.txt"
printf "# custom requirements\n" > "$fixture/deps/pip-requirements.txt"
for mode in default explicit dependencies fallback; do
  extra=(); expected=33
  case "$mode" in
    explicit|dependencies) extra+=(-e ANSIBLE_CONFIG=/site/ansible.cfg); expected=77;;
    fallback) extra+=(-e ANSIBLE_CONFIG=/missing/ansible.cfg -v "$fixture/site/ansible.cfg:/etc/ansible/ansible.cfg:ro"); expected=77;;
  esac
  if [ "$mode" = dependencies ]; then extra+=(-e CONTROLLER_CONFIG_DIR=/dependencies); fi
  container=$(docker run -d --network none -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
    -e CONTROLLER_LOG_DIR=/tmp/dependency-logs \
    -v "$fixture/default:/configs" -v "$fixture/site:/site:ro" \
    -v "$fixture/deps:/dependencies" "${extra[@]}" "$image")
  for attempt in $(seq 1 30); do
    docker exec "$container" pgrep sshd >/dev/null 2>&1 && break
    sleep 1
  done
  docker exec "$container" pgrep sshd >/dev/null
  docker exec "$container" /usr/local/bin/install-deps.sh pip
  dependency_dir=/configs
  [ "$mode" != dependencies ] || dependency_dir=/dependencies
  docker exec "$container" sh -ec 'checksum=$(sha256sum "$1/pip-requirements.txt"); grep -q "sha256=${checksum%% *}" /tmp/dependency-logs/pip-install.status' sh "$dependency_dir"
  docker exec "$container" ansible-config dump | grep -E "^DEFAULT_FORKS.* = $expected$"
  docker exec "$container" bash -euc '
    ssh-keygen -q -t ed25519 -N "" -f /tmp/test-key
    cp /tmp/test-key.pub /home/ansible/.ssh/authorized_keys
    chown -R ansible:ansible /home/ansible/.ssh
    chmod 700 /home/ansible/.ssh
    chmod 600 /home/ansible/.ssh/authorized_keys
    # Trust this disposable server from its own generated key, no TOFU bypass.
    printf "localhost " > /tmp/known-hosts
    cat /etc/ssh/host_keys/ssh_host_ed25519_key.pub >> /tmp/known-hosts
    ssh -i /tmp/test-key -o UserKnownHostsFile=/tmp/known-hosts -o BatchMode=yes \
      ansible@localhost ansible-config dump
  ' | grep -E "^DEFAULT_FORKS.* = $expected$"
  docker rm -f "$container" >/dev/null; container=""
done
