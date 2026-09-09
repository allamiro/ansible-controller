#!/bin/bash
# Stand up the controller-entrypoint extension (compose.ctl.yml) and wire the
# GitLab side: per-environment fetch tokens on the controller, the CI→ctl SSH
# credential pair, the PINNED host key, and the protected CI variables.
# Idempotent; called by lab-up.sh, runnable alone against a live lab.
set -euo pipefail
cd "$(dirname "$0")/../../.."
LAB="mesh/labs/gitlab"
STATE="$LAB/.lab-state"
GL="http://localhost:8929/api/v4"
unset COMPOSE_PROJECT_NAME
say() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
PAT=$(cat "$STATE/pat") || die "no PAT — run lab-up.sh first"
glab() { local m="$1" p="$2"; shift 2; curl -sfS -X "$m" -H "PRIVATE-TOKEN: $PAT" "$GL$p" "$@"; }
PID=$(glab GET "/projects/root%2Fmesh-automation" | jq -r .id)

say "fetch credential: read-only deploy token, one file per environment"
mkdir -p "$STATE/ctl-secrets"
if ! grep -q : "$STATE/ctl-secrets/lab-mesh.token" 2>/dev/null; then
  resp=$(glab POST "/projects/$PID/deploy_tokens" \
    --data-urlencode "name=ctl-fetch-$(date +%s)" \
    --data-urlencode "scopes[]=read_repository")
  tok=$(jq -r .token <<<"$resp"); user=$(jq -r .username <<<"$resp")
  [ -n "$tok" ] && [ "$tok" != null ] || die "deploy token creation failed"
  # deploy tokens authenticate ONLY with their generated username — store both
  (umask 077
   for e in lab-direct lab-mesh lab-mesh-win; do echo "$user:$tok" > "$STATE/ctl-secrets/$e.token"; done)
fi
# owner-only on the host; ctl-run reads them as root (forced-command sudo)
chmod 700 "$STATE/ctl-secrets"; chmod 600 "$STATE/ctl-secrets/"*.token

say "CI -> ctl SSH keypair and authorized_keys"
mkdir -p "$STATE/ctl-ssh" "$STATE/target-ssh"
if [ ! -f "$STATE/ctl-ssh/ci_ed25519" ]; then
  # in-container: a FIPS-mode host's ssh-keygen refuses ed25519; the image's
  # openssh falls back to its default provider (same pattern as e2e-up.sh)
  docker run --rm -v "$PWD/$STATE/ctl-ssh":/w --entrypoint bash ansible-orchestrator:e2e -euc \
    'ssh-keygen -q -t ed25519 -N "" -C "gitlab-ci->ctl" -f /w/ci_ed25519; chown '"$(id -u):$(id -g)"' /w/ci_ed25519 /w/ci_ed25519.pub'
fi
# restrict + forced command: this key invokes ctl-run and nothing else —
# no pty, no forwarding, no shell (see bin/ctl-shell)
printf 'restrict,command="/usr/local/lab-bin/ctl-shell" %s\n' "$(cat "$STATE/ctl-ssh/ci_ed25519.pub")" \
  > "$STATE/ctl-ssh/authorized_keys"
# sshd StrictModes: ~/.ssh and authorized_keys must belong to the login
# user (uid 1000) REGARDLESS of the host account's uid — chown the DIR too
chmod 755 "$STATE/ctl-ssh"; chmod 644 "$STATE/ctl-ssh/authorized_keys" "$STATE/ctl-ssh/ci_ed25519.pub"; chmod 600 "$STATE/ctl-ssh/ci_ed25519"
docker run --rm -v "$PWD/$STATE/ctl-ssh":/w --entrypoint sh ansible-orchestrator:e2e -euc \
  'chown 1000:1000 /w /w/authorized_keys && chmod 700 /w || chmod 755 /w' 2>/dev/null || true

say "direct-target trusts the controller's target key"
docker run --rm -v mesh-e2e_e2e-ssh:/k:ro -v "$PWD/$STATE/target-ssh":/t \
  --entrypoint sh ansible-orchestrator:e2e -euc \
  'cp /k/id_ed25519.pub /t/authorized_keys; chown 1000:1000 /t /t/authorized_keys; chmod 700 /t 2>/dev/null || true; chmod 644 /t/authorized_keys' 

say "ctl + direct-target containers"
docker compose -f "$LAB/compose.ctl.yml" up -d --wait
# the staging volume must belong to the ssh login user ctl-run runs as
docker exec -u 0 gitlab-lab-ctl chown ansible:ansible /var/lib/gitlab-runs

say "pin ctl's host key INDEPENDENTLY (read from its host-key volume, not keyscan)"
hk=$(docker exec gitlab-lab-ctl sh -c 'cut -d" " -f1,2 /etc/ssh/host_keys/ssh_host_ed25519_key.pub')
[ -n "$hk" ] || die "could not read ctl host key"
printf 'ctl.lab.local %s\n' "$hk" > "$STATE/ctl-known-hosts"

say "protected CI variables: CTL_SSH_KEY + CTL_KNOWN_HOSTS (file type)"
# scoped to lab-* environments: several controllers (lab, prod, ...) share
# one project by scoping their channel variables to their environments
setvar() { # key file
  glab DELETE "/projects/$PID/variables/$1?filter%5Benvironment_scope%5D=lab-*" >/dev/null 2>&1 || true
  glab POST "/projects/$PID/variables" \
    --data-urlencode "key=$1" --data-urlencode "value@$2" \
    --data-urlencode "variable_type=file" --data-urlencode "protected=true" \
    --data-urlencode "environment_scope=lab-*" >/dev/null
}
setvar CTL_SSH_KEY "$STATE/ctl-ssh/ci_ed25519"
setvar CTL_KNOWN_HOSTS "$STATE/ctl-known-hosts"
glab DELETE "/projects/$PID/variables/CTL_HOST?filter%5Benvironment_scope%5D=lab-*" >/dev/null 2>&1 || true
glab POST "/projects/$PID/variables" --data-urlencode "key=CTL_HOST" \
  --data-urlencode "value=ctl.lab.local" --data-urlencode "protected=true" \
  --data-urlencode "environment_scope=lab-*" >/dev/null

say "ctl extension is up (ssh ansible@ctl.lab.local from labnet; envs: lab-direct, lab-mesh, lab-mesh-win)"
