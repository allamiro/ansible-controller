#!/bin/sh
set -eu
# Generate host keys on first start into /etc/ssh/host_keys (see sshd_config.d
# drop-in). Only this directory is volume-persisted so sshd_config/moduli keep
# tracking the image.
mkdir -p /etc/ssh/host_keys
for t in rsa ecdsa ed25519; do
  key="/etc/ssh/host_keys/ssh_host_${t}_key"
  case "$t" in
    rsa)     want="ssh-rsa " ;;
    ecdsa)   want="ecdsa-sha2-" ;;
    ed25519) want="ssh-ed25519 " ;;
  esac
  # Trust a persisted key only if it parses AND matches the expected algorithm:
  # a stale volume may hold a truncated key or one of the wrong type, either of
  # which would keep sshd from starting. </dev/null so a passphrase-protected
  # key fails fast instead of prompting on a TTY.
  pub="$(ssh-keygen -y -f "$key" </dev/null 2>/dev/null || true)"
  case "$pub" in
    "$want"*) ;;
    *)
      rm -f "$key" "${key}.pub"
      ssh-keygen -q -N '' -t "$t" -f "$key"
      ;;
  esac
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