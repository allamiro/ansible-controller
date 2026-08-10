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

# Auto-install Galaxy roles/collections declared in /configs/requirements.yml
# into /configs/.galaxy (host-persisted rw mount, so installs survive container
# recreation). Runs in the background so sshd startup is never delayed and an
# offline host is not fatal; see /var/log/ansible/galaxy-install.log for output.
# The flock serializes against `make galaxy`, which takes the same lock — so a
# manual install can't race this one, and running `make galaxy` after `make up`
# blocks until startup installation has finished (making content ready).
if [ -f /configs/requirements.yml ]; then
  mkdir -p /configs/.galaxy
  (
    flock 9
    ansible-galaxy role install -r /configs/requirements.yml \
      --roles-path /configs/.galaxy/roles || true
    ansible-galaxy collection install -r /configs/requirements.yml \
      -p /configs/.galaxy/collections || true
    chown -R ansible:ansible /configs/.galaxy || true
  ) 9>>/configs/.galaxy/.install.lock >>/var/log/ansible/galaxy-install.log 2>&1 &
fi

# Extra controller-side Python packages (cloud SDKs for dynamic inventory,
# alternative WinRM transports, ...) declared in /configs/pip-requirements.txt
# are installed at startup. Same background+lock pattern as Galaxy content;
# `make pip` installs on demand and waits for an in-flight install.
if [ -f /configs/pip-requirements.txt ]; then
  (
    flock 9
    pip3 install --no-cache-dir --break-system-packages \
      -r /configs/pip-requirements.txt || true
  ) 9>>/configs/.pip-install.lock >>/var/log/ansible/pip-install.log 2>&1 &
fi

# Ansible Vault password: set the ANSIBLE_VAULT_PASSWORD env var or drop a
# password file at /configs/.vault_pass. Either source is copied to a file only
# the ansible user can read (a bind-mounted file's host ownership may not match
# uid 1000, and root can always read the source). The path is exported to SSH
# sessions — including one-shot `ssh host cmd` runs, which skip profile files —
# via pam_env's /etc/environment, and to `bash -lc` docker-exec shells via
# /etc/profile.d.
vault_src=""
if [ -n "${ANSIBLE_VAULT_PASSWORD:-}" ]; then
  vault_src=env
elif [ -f /configs/.vault_pass ]; then
  vault_src=file
fi
if [ -n "$vault_src" ]; then
  vault_pass_file=/home/ansible/.vault_pass
  umask 077
  if [ "$vault_src" = env ]; then
    printf '%s\n' "$ANSIBLE_VAULT_PASSWORD" > "$vault_pass_file"
  else
    cat /configs/.vault_pass > "$vault_pass_file"
  fi
  umask 022
  chown ansible:ansible "$vault_pass_file"
  touch /etc/environment
  sed -i '/^ANSIBLE_VAULT_PASSWORD_FILE=/d' /etc/environment
  echo "ANSIBLE_VAULT_PASSWORD_FILE=$vault_pass_file" >> /etc/environment
  printf 'export ANSIBLE_VAULT_PASSWORD_FILE=%s\n' "$vault_pass_file" \
    > /etc/profile.d/ansible-vault.sh
  chmod 644 /etc/profile.d/ansible-vault.sh
fi

# Lock down SSH; root login disabled
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config

# .ssh is bind-mounted read-only from the host; do not attempt chmod/chown here.
# Required host-side setup before starting the container:
#   chmod 700 ./ssh
#   chmod 600 ./ssh/authorized_keys
#   chown -R 1000:1000 ./ssh   # if host enforces uid matching

exec /usr/sbin/sshd -D -e