#!/bin/sh
set -eu
# Generate host keys on first start into /etc/ssh/host_keys (see sshd_config.d
# drop-in). Only this directory is volume-persisted so sshd_config/moduli keep
# tracking the image.
mkdir -p /etc/ssh/host_keys
for t in rsa ecdsa ed25519; do
  key="/etc/ssh/host_keys/ssh_host_${t}_key"
  # -y validates the key is readable/usable, not merely present: a stale volume
  # may hold a zero-byte or truncated key that would keep sshd from starting
  if ! ssh-keygen -y -f "$key" >/dev/null 2>&1; then
    rm -f "$key" "${key}.pub"
    ssh-keygen -q -N '' -t "$t" -f "$key"
  fi
done

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