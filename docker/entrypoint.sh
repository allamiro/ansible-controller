#!/bin/sh
set -eu
# fd 3 stays attached to the container log: the background installs below send
# their own output to log FILES, so a failure would otherwise be invisible to
# `docker logs` and to anyone who never opens /var/log/ansible.
exec 3>&2
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

# ANSIBLE_CONFIG is fixed in the container environment (default /configs/ansible.cfg).
# Never override it only in PID 1: later docker exec calls must see the same value.
# Missing config files follow Ansible's normal discovery, including /etc/ansible.
python3 /usr/local/bin/controller-env.py
# Ensure log directory exists and is writable (volume is rw)
mkdir -p "${CONTROLLER_LOG_DIR:-/var/log/ansible}" || true
chown -R "${CONTROLLER_USER:-ansible}:${CONTROLLER_USER:-ansible}" "${CONTROLLER_LOG_DIR:-/var/log/ansible}" || true

# Declared dependency content is installed in the background so sshd startup is
# never delayed and an offline host is not fatal. install-deps.sh holds the same
# per-target lock `make galaxy` / `make pip` take, records the outcome where
# `make preflight` reads it, and announces a failure on the container log (fd 3)
# — one implementation, so a later manual retry refreshes the same record.
for dep in galaxy pip; do
  /usr/local/bin/install-deps.sh "$dep" 3>&3 &
done

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
else
  # Vault deconfigured (env var unset / file removed) — on a docker restart the
  # container filesystem survives, so revoke state written by an earlier start
  # or sessions would keep decrypting with the old password.
  rm -f /home/ansible/.vault_pass /etc/profile.d/ansible-vault.sh
  if [ -f /etc/environment ]; then
    sed -i '/^ANSIBLE_VAULT_PASSWORD_FILE=/d' /etc/environment
  fi
fi

# Lock down SSH; root login disabled
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config

# The shipped ansible.cfg disables managed-host key verification for
# first-run convenience. That is a deliberate lab default, not a production
# one: with it off, Ansible accepts any host key, so an attacker who can answer
# for a target's address reads whatever those plays carry. Say so at every
# start, naming the file that decided it, rather than leaving it to whoever
# reads the config. Never fatal — a controller must still start.
# force_color in the shipped config makes ansible-config emit ANSI escapes even
# when piped, so strip them before matching.
src="$(ansible-config dump 2>/dev/null | sed "s/$(printf '\033')\[[0-9;]*m//g" \
       | sed -n 's/^HOST_KEY_CHECKING(\(.*\)) = False.*/\1/p' | head -1)"
if [ -n "$src" ]; then
  echo "entrypoint: WARNING managed-host SSH key verification is DISABLED by $src." >&3
  echo "entrypoint:          Set host_key_checking = True (and drop the StrictHostKeyChecking=no ssh_args) before" >&3
  echo "entrypoint:          production use; see the known-hosts procedure in docs/README.md. 'make preflight' rechecks." >&3
fi

# .ssh is bind-mounted read-only from the host; do not attempt chmod/chown here.
# Required host-side setup before starting the container:
#   chmod 700 ./ssh
#   chmod 600 ./ssh/authorized_keys
#   chown -R 1000:1000 ./ssh   # if host enforces uid matching

exec /usr/sbin/sshd -D -e
