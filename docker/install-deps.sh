#!/bin/sh
# Install the dependency content a site declares, and record the outcome.
#
#   install-deps.sh galaxy [--force]   configs/requirements.yml
#   install-deps.sh pip                configs/pip-requirements.txt
#
# One implementation, used by the container entrypoint at startup and by
# `make galaxy` / `make pip` afterwards. That matters beyond tidiness: the
# status file is what `make preflight` reports, so a manual retry has to refresh
# the same record the startup install wrote, or a fixed installation keeps being
# reported as broken until the container restarts.
#
# Never fatal to the caller's startup: a failure is recorded and announced, not
# raised, because an offline Galaxy must not stop a controller from serving.
set -u
CONFIG_DIR="${CONTROLLER_CONFIG_DIR:-/configs}"
LOG_DIR="${CONTROLLER_LOG_DIR:-/var/log/ansible}"
OWNER="${CONTROLLER_USER:-ansible}"

what="${1:?usage: install-deps.sh galaxy|pip [--force]}"
force=""
[ "${2:-}" = "--force" ] && force="--force"

mkdir -p "$LOG_DIR" 2>/dev/null || true

case "$what" in
  galaxy)
    req="$CONFIG_DIR/requirements.yml"
    lock="$CONFIG_DIR/.galaxy/.install.lock"
    log="$LOG_DIR/galaxy-install.log"
    status="$LOG_DIR/galaxy-install.status"
    mkdir -p "$CONFIG_DIR/.galaxy"
    ;;
  pip)
    req="$CONFIG_DIR/pip-requirements.txt"
    lock="$CONFIG_DIR/.pip-install.lock"
    log="$LOG_DIR/pip-install.log"
    status="$LOG_DIR/pip-install.status"
    ;;
  *) echo "install-deps.sh: unknown target '$what'" >&2; exit 2;;
esac

[ -f "$req" ] || exit 0

# fd 3 is the caller's own output when it provides one (the entrypoint hands it
# the container log); otherwise stderr, so a manual run still says what happened.
exec 3>&2 2>/dev/null || true
run() {
  # Invalidate the previous result before doing work: an interrupted retry must
  # not leave an earlier success looking current. Fingerprint before installing
  # so edits made during installation cannot certify the new requirements.
  rm -f "$status" || return 1
  checksum=$(sha256sum "$req") || return 1
  checksum=${checksum%% *}
  rc=0
  case "$what" in
    galaxy)
      ansible-galaxy role install -r "$req" --roles-path "$CONFIG_DIR/.galaxy/roles" $force || rc=$?
      ansible-galaxy collection install -r "$req" -p "$CONFIG_DIR/.galaxy/collections" $force || rc=$?
      chown -R "$OWNER:$OWNER" "$CONFIG_DIR/.galaxy" 2>/dev/null || true
      ;;
    pip)
      pip3 install --no-cache-dir --break-system-packages -r "$req" || rc=$?
      ;;
  esac
  temporary=$(mktemp "$status.XXXXXX") || return 1
  if ! { printf 'rc=%s finished=%s sha256=%s\n' "$rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$checksum" > "$temporary" && mv "$temporary" "$status"; }; then
    rm -f "$temporary"
    return 1
  fi
  [ "$rc" -eq 0 ] \
    || echo "install-deps: WARNING $what install failed (rc=$rc) — see $log; 'make preflight' reports this" >&3
  return "$rc"
}

( flock 9 || exit 1; run ) 9>>"$lock" >>"$log" 2>&1
