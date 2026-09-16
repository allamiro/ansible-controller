#!/bin/sh
# Answer one question before a play runs: is this controller actually ready, and
# is it configured the way you think it is?
#
# Runs INSIDE the controller container (`make preflight` pipes it in, so it works
# against a published image without a rebuild). Reports startup dependency
# installs, managed-host key verification, the Vault password, the inventory and
# target SSH credentials.
#
#   exit 0  nothing broken
#   exit 1  something is broken (failed install, unparseable inventory)
#   --strict also fails on risky-but-deliberate settings, for production gating
set -u
strict=0
case "$*" in
  '') ;;
  --strict) strict=1;;
  *) echo 'usage: preflight.sh [--strict]' >&2; exit 2;;
esac

# Nothing below is baked in. Every location is derived from the environment the
# controller actually runs with, so a site that mounts its configuration
# somewhere else, logs somewhere else, or runs Ansible as a different account
# gets a correct report instead of one about paths it does not use. Each can
# still be overridden explicitly.
nocolor() { sed "s/$(printf '\033')\[[0-9;]*m//g"; }
read_config() {
  # Capture before filtering: a pipeline would hide ansible-config's failure.
  if ! config_dump=$(ansible-config dump 2>/dev/null); then
    echo 'preflight: FAILED — cannot read Ansible configuration' >&2
    exit 1
  fi
  config_dump=$(printf '%s\n' "$config_dump" | nocolor)
}
dump() { printf '%s\n' "$config_dump"; }
read_config

CONFIG_FILE="${ANSIBLE_CONFIG:-}"
if [ -z "$CONFIG_FILE" ]; then
  CONFIG_FILE=$(dump | sed -n 's/^CONFIG_FILE(.*) = \(.*\)/\1/p' | head -1)
fi
[ "$CONFIG_FILE" = "None" ] && CONFIG_FILE=""
CONFIG_DIR="${CONTROLLER_CONFIG_DIR:-$([ -n "$CONFIG_FILE" ] && dirname "$CONFIG_FILE" || echo /configs)}"

# An image built before ANSIBLE_CONFIG was set in the Dockerfile — the published
# image this is advertised to work against — gives `docker exec` no config at
# all, and Ansible never walks up from the working directory to find one. Left
# alone, every check below would then describe /etc/ansible/hosts and Ansible's
# default host-key policy instead of the configuration this controller runs.
if [ -z "$CONFIG_FILE" ] && [ -f "$CONFIG_DIR/ansible.cfg" ]; then
  ANSIBLE_CONFIG="$CONFIG_DIR/ansible.cfg"
  export ANSIBLE_CONFIG
  CONFIG_FILE="$ANSIBLE_CONFIG"
  echo "    (using $CONFIG_FILE; this container's image does not set ANSIBLE_CONFIG)"
  read_config
fi

# Deriving this from ansible's log_path was wrong: the entrypoint writes the
# install logs and their status files to a fixed location regardless of where a
# site points log_path, so a customised log_path made a finished install read as
# "not recorded yet" and could hide a real failure. Read where the writer writes.
LOG_DIR="${CONTROLLER_LOG_DIR:-/var/log/ansible}"

# The LOCAL account whose home holds the Vault password and the target SSH keys.
# Deliberately not Ansible's remote_user: that names the account on the managed
# host, so a site connecting as "ubuntu" would have sent these checks to
# /home/ubuntu while the entrypoint kept writing to the controller account.
RUN_USER="${CONTROLLER_USER:-ansible}"
RUN_HOME="${CONTROLLER_HOME:-$(getent passwd "$RUN_USER" 2>/dev/null | cut -d: -f6)}"
[ -n "$RUN_HOME" ] || RUN_HOME="/home/$RUN_USER"

fails=0
risks=0
say()  { printf '\n==> %s\n' "$*"; }
ok()   { printf '    %-46s %s\n' "$1" "ok${2:+ — $2}"; }
risk() { printf '    %-46s %s\n' "$1" "RISK — $2"; risks=$((risks + 1)); }
bad()  { printf '    %-46s %s\n' "$1" "FAILED — $2"; fails=$((fails + 1)); }
note() { printf '    %-46s %s\n' "$1" "$2"; }

# ---- startup dependency installs ------------------------------------------
# The entrypoint installs declared Galaxy and pip content in the BACKGROUND, so
# a play dispatched immediately after `make up` can outrun it. Report in-flight
# installs as clearly as failed ones: both make a play fail on the managed host
# for reasons that have nothing to do with the play.
say "startup dependency installs"
check_install() { # label requirements-file status-file lock-file log-file
  if [ ! -f "$2" ]; then note "$1" "not configured ($2 absent)"; return; fi
  if [ -f "$4" ] && ! flock -n "$4" true 2>/dev/null; then
    risk "$1" "still installing — a play started now may not see its content"
    return
  fi
  if [ ! -f "$3" ]; then risk "$1" "declared, but no install recorded yet ($3)"; return; fi
  rc=$(sed -n 's/^rc=\([0-9]*\).*/\1/p' "$3")
  fin=$(sed -n 's/.*finished=\([^ ]*\).*/\1/p' "$3")
  if [ "${rc:-1}" = 0 ]; then ok "$1" "installed ${fin:-}"; else bad "$1" "install rc=$rc — see $5"; fi
}
check_install "Galaxy content (requirements.yml)" "$CONFIG_DIR/requirements.yml" \
  "$LOG_DIR/galaxy-install.status" "$CONFIG_DIR/.galaxy/.install.lock" "$LOG_DIR/galaxy-install.log"
check_install "Python packages (pip-requirements.txt)" "$CONFIG_DIR/pip-requirements.txt" \
  "$LOG_DIR/pip-install.status" "$CONFIG_DIR/.pip-install.lock" "$LOG_DIR/pip-install.log"

# ---- managed-host SSH key verification -------------------------------------
say "managed-host SSH key verification"
hk=$(dump | sed -n 's/^HOST_KEY_CHECKING(\(.*\)) = \(.*\)/\2 \1/p' | head -1)
case "$hk" in
  True*)  ok   "host_key_checking" "enabled by ${hk#True }";;
  False*) risk "host_key_checking" "DISABLED by ${hk#False } — any host key is accepted";;
  *)      note "host_key_checking" "could not be determined";;
esac
if ssh_config=$(ansible-config dump -t connection ssh 2>/dev/null); then
  if printf '%s\n' "$ssh_config" | nocolor | grep -Ei "^ssh_(args|common_args|extra_args)\(.*StrictHostKeyChecking[=[:space:]]+(no|off|false)($|[[:space:]\"'])" >/dev/null; then
    risk "SSH options" "disable StrictHostKeyChecking, overriding the global host-key policy"
  fi
else
  bad "SSH options" "could not read SSH connection configuration"
fi

# ---- Ansible Vault ---------------------------------------------------------
say "Ansible Vault password"
vp=$(dump | sed -n 's/^DEFAULT_VAULT_PASSWORD_FILE(.*) = \(.*\)/\1/p' | head -1)
case "$vp" in None) vp="";; esac
vp="${ANSIBLE_VAULT_PASSWORD_FILE:-$vp}"
vault_configured="$vp"
vp="${vp:-$RUN_HOME/.vault_pass}"
if [ -f "$vp" ]; then
  mode=$(stat -c %a "$vp" 2>/dev/null)
  case "$mode" in
    600|400) ok "$vp" "mode $mode";;
    *)       risk "$vp" "mode $mode — should be 600, readable only by its owner";;
  esac
elif [ -n "$vault_configured" ]; then
  bad "$vp" "configured Vault password file does not exist"
else
  note "vault password" "not configured (set ANSIBLE_VAULT_PASSWORD or $CONFIG_DIR/.vault_pass)"
fi

# ---- inventory -------------------------------------------------------------
say "inventory"
# Ask Ansible to resolve its OWN configured sources rather than picking one path
# out of the dump: `inventory` may list several files, or name a directory or a
# plugin, and flattening that list produced a path that exists nowhere, failing
# a configuration that works.
inv_raw=$(dump | sed -n 's/^DEFAULT_HOST_LIST(.*) = \(.*\)/\1/p' | head -1)
inv_list=$(python3 - "$inv_raw" <<'PY' 2>/dev/null || true
import ast, sys
try:
    v = ast.literal_eval(sys.argv[1])
except Exception:
    v = sys.argv[1]
print("\n".join(str(x) for x in (v if isinstance(v, (list, tuple)) else [v])))
PY
)
[ -n "$inv_list" ] || inv_list="$CONFIG_DIR/inventory/hosts.ini"
label=$(printf '%s' "$inv_list" | tr '\n' ' ')
# Ansible normally warns and skips invalid sources, even if another source
# works. A readiness check must reject that partial inventory. Preserve the
# command's exit code separately from JSON parsing, and never print hostvars.
if inventory_json=$(ANSIBLE_INVENTORY_ANY_UNPARSED_IS_FAILED=True ansible-inventory --list 2>/dev/null) &&
   hosts=$(printf '%s\n' "$inventory_json" | python3 -c '
import json, sys
inventory = json.load(sys.stdin)
hosts = set(inventory.get("_meta", {}).get("hostvars", {}))
for name, group in inventory.items():
    if name != "_meta":
        hosts.update(group.get("hosts", []))
print(len(hosts))
' 2>/dev/null); then
  if [ "${hosts:-0}" -gt 0 ]; then
    ok "$label" "$hosts host(s)"
  else
    risk "$label" "parses, but resolves 0 hosts"
  fi
else
  bad "$label" "configured inventory does not parse completely"
fi

# ---- target SSH credentials ------------------------------------------------
say "target SSH credentials"
check_key() { # path label
  if [ ! -f "$1" ]; then bad "$1" "$2 does not exist"; return; fi
  # docker exec runs as root, but SSH sessions use the controller account.
  # A restrictive mode alone says nothing about access through a bind mount.
  if [ "$(id -un)" = "$RUN_USER" ]; then
    readable=0
    [ -r "$1" ] && readable=1
  elif [ "$(id -u)" = 0 ]; then
    readable=0
    runuser -u "$RUN_USER" -- test -r "$1" 2>/dev/null && readable=1
  else
    bad "$1" "cannot verify readability as $RUN_USER; run preflight as root or $RUN_USER"
    return
  fi
  if [ "$readable" = 0 ]; then
    bad "$1" "$2 is not readable by $RUN_USER"
    return
  fi
  mode=$(stat -c %a "$1" 2>/dev/null)
  case "$mode" in
    600|400) ok "$1" "$2, mode $mode";;
    *)       risk "$1" "$2, mode $mode — OpenSSH refuses group/world-readable keys";;
  esac
}
# A configured private_key_file is the credential plays actually use, wherever it
# lives; only when none is configured does the account's own .ssh matter.
configured_key=$(dump | sed -n 's/^DEFAULT_PRIVATE_KEY_FILE(.*) = \(.*\)/\1/p' | head -1)
case "$configured_key" in None) configured_key="";; esac
if [ -n "$configured_key" ]; then
  check_key "$configured_key" "configured private_key_file"
else
  found=0
  for k in "$RUN_HOME"/.ssh/id_*; do
    case "$k" in *.pub|*'/id_*') continue;; esac
    found=1
    check_key "$k" "account key"
  done
  [ "$found" = 1 ] || note "private key" "none configured and none in $RUN_HOME/.ssh (password or Vault auth only)"
fi

# ---- verdict ---------------------------------------------------------------
printf '\n'
if [ "$fails" -gt 0 ]; then
  echo "preflight: $fails failure(s), $risks risk(s) — fix the failures before running a play"
  exit 1
fi
if [ "$risks" -gt 0 ]; then
  echo "preflight: no failures, $risks risk(s) above"
  [ "$strict" = 1 ] && { echo "preflight: --strict, so risks are fatal"; exit 1; }
  exit 0
fi
echo "preflight: all checks passed"
