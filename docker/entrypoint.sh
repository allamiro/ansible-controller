#!/bin/sh
set -eu
test -f /etc/ssh/ssh_host_rsa_key || ssh-keygen -A

# Prefer host-provided cfg/inventory if mounted under /configs
if [ -f /configs/ansible.cfg ]; then
  export ANSIBLE_CONFIG=/configs/ansible.cfg
fi
# If your cfg sets log_path, ensure directory exists
mkdir -p /var/log/ansible || true
chown -R ansible:ansible /var/log/ansible || true

# Lock down SSH; allow only 'ansible'; root login disabled
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
# (optional) use host-provided authorized_keys file if mounted
if [ -f /home/ansible/.ssh/authorized_keys ]; then chmod 600 /home/ansible/.ssh/authorized_keys; fi
mkdir -p /home/ansible/.ssh
chown -R ansible:ansible /home/ansible/.ssh
chmod 700 /home/ansible/.ssh

exec /usr/sbin/sshd -D -e