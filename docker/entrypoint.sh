#!/bin/sh
set -eu
test -f /etc/ssh/ssh_host_rsa_key || ssh-keygen -A

# Prefer host-provided cfg/inventory if mounted under /configs
if [ -f /configs/ansible.cfg ]; then
  export ANSIBLE_CONFIG=/configs/ansible.cfg
fi
# Ensure log directory exists and is writable (volume is rw)
mkdir -p /var/log/ansible || true
chown -R ansible:ansible /var/log/ansible || true

# Lock down SSH; root login disabled
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config

# .ssh is bind-mounted read-only from the host; do not attempt chmod/chown here.
# Required host-side setup before starting the container:
#   chmod 700 ./ssh
#   chmod 600 ./ssh/authorized_keys
#   chown -R 1000:1000 ./ssh   # if host enforces uid matching

exec /usr/sbin/sshd -D -e