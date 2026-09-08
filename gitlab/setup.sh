#!/bin/bash
# Bootstrap the production-shaped GitLab integration on this box.
#
#   gitlab/setup.sh <gitlab-url> [project-path]
#     gitlab-url    e.g. http://localhost:8929 — an ALREADY RUNNING GitLab
#                   (this instance's API must be reachable from this host;
#                   a root PAT must exist at gitlab/.gitlab-state/pat, or
#                   be readable from the disposable lab's state)
#     project-path  default root/mesh-automation
#
# Idempotent. Produces, under gitlab/.gitlab-state/ (gitignored):
#   environments.yml    from the example, if absent
#   ctl-secrets/        per-env read-only deploy tokens (<user>:<token>)
#   ci_ed25519[.pub]    the CI->controller key (forced command)
#   ctl-known-hosts     the controller's PINNED host key
# and on GitLab: protected file variables CTL_SSH_KEY / CTL_KNOWN_HOSTS.
# It also appends the restricted CI key to ./ssh/authorized_keys (created
# if needed) and verifies the controller container answers over SSH.
set -euo pipefail
cd "$(dirname "$0")/.."
GLURL="${1:?usage: gitlab/setup.sh <gitlab-url> [project-path]}"
# every name is a parameter: override via environment
CTL_HOST="${CTL_HOST:-ctl.prod.local}"
PROJ="${2:-root/mesh-automation}"
STATE="gitlab/.gitlab-state"
say() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
mkdir -p "$STATE/ctl-secrets"
echo 0 > "$STATE/fips0"

# a PAT: own state first, then the disposable lab's
PATF="$STATE/pat"
[ -s "$PATF" ] || { [ -s mesh/labs/gitlab/.lab-state/pat ] && cp mesh/labs/gitlab/.lab-state/pat "$PATF"; }
[ -s "$PATF" ] || die "no root PAT at $PATF — create one (UI: profile > access tokens, scope api) and save it there"
PAT=$(cat "$PATF")
# the token travels via a 0600 curl config file, never argv (visible in ps)
(umask 077; printf 'header = "PRIVATE-TOKEN: %s"\n' "$PAT" > "$STATE/.curl-auth")
glab() { local m="$1" p="$2"; shift 2; curl -sfS -K "$STATE/.curl-auth" -X "$m" "$GLURL/api/v4$p" "$@"; }
glab GET /user >/dev/null || die "PAT does not authenticate against $GLURL"
ENC=$(printf %s "$PROJ" | sed 's|/|%2F|g')
if ! PID=$(glab GET "/projects/$ENC" 2>/dev/null | jq -r .id) || [ -z "$PID" ] || [ "$PID" = null ]; then
  say "project $PROJ absent — creating and seeding it (fresh-GitLab path)"
  glab POST /projects --data-urlencode "name=$(basename "$PROJ")" \
    --data-urlencode "visibility=private" --data-urlencode "initialize_with_readme=false" >/dev/null
  PID=$(glab GET "/projects/$ENC" | jq -r .id)
  [ -n "$PID" ] && [ "$PID" != null ] || die "project creation failed"
  seed=$(mktemp -d); cp -r mesh/labs/gitlab/project-seed/. "$seed/"
  # the seed pipeline ships lab-* environment names (the disposable lab runs
  # under them); this fresh path provisions prod-* CI variables, deploy tokens,
  # and env-map entries, so rewrite the seeded pipeline to the prod-* names it
  # will actually run under (else deploy jobs get no CTL_SSH_KEY by scope, or
  # ctl-run rejects an undefined environment)
  sed -i 's/\blab-direct\b/prod-direct/g; s/\blab-mesh\b/prod-mesh/g' "$seed/.gitlab-ci.yml"
  git -C "$seed" init -q -b main
  git -C "$seed" -c user.name="Lab Operator" -c user.email="lab@lab.local" add -A
  git -C "$seed" -c user.name="Lab Operator" -c user.email="lab@lab.local" commit -qm "seed: mesh automation project"
  # push over an askpass helper: the root PAT reaches git only through the
  # environment, never argv (visible via ps/proc) or a persisted remote
  askpass=$(mktemp); chmod 700 "$askpass"
  printf '#!/bin/sh\ncase "$1" in Username*) echo root;; *) printf %%s "$GL_PUSH_PAT";; esac\n' > "$askpass"
  GL_PUSH_PAT="$PAT" GIT_ASKPASS="$askpass" GIT_TERMINAL_PROMPT=0 \
    git -C "$seed" push -q "$GLURL/$PROJ.git" main
  rm -f "$askpass"
  rm -rf "$seed"
fi

# governance for BOTH fresh and existing projects (idempotent): main protected
# (no push; Maintainer merge) + merges require green pipelines. Applying this
# outside the creation branch stops an existing project's deploy jobs from
# stranding on the ref_protected runner, or a loose project bypassing the gate.
glab POST "/projects/$PID/protected_branches" --data-urlencode "name=main" \
  --data-urlencode "push_access_level=0" --data-urlencode "merge_access_level=40" \
  --data-urlencode "allow_force_push=false" >/dev/null 2>&1 || true
glab PUT "/projects/$PID" --data-urlencode "only_allow_merge_if_pipeline_succeeds=true" >/dev/null
# tag-deploy runs on the protected runner: releases need protected tags
glab GET "/projects/$PID/protected_tags/v%2A" >/dev/null 2>&1 || \
  glab POST "/projects/$PID/protected_tags" --data-urlencode "name=v*" \
    --data-urlencode "create_access_level=40" >/dev/null 2>&1 || true

say "environment map"
[ -s "$STATE/environments.yml" ] || cp gitlab/environments.example.yml "$STATE/environments.yml"

say "fetch credential (read-only deploy token, one file per env)"
if ! grep -qs : "$STATE/ctl-secrets/prod-mesh.token"; then
  resp=$(glab POST "/projects/$PID/deploy_tokens" \
    --data-urlencode "name=ctl-prod-fetch-$(date +%s)" \
    --data-urlencode "scopes[]=read_repository")
  tok=$(jq -r .token <<<"$resp"); user=$(jq -r .username <<<"$resp")
  [ -n "$tok" ] && [ "$tok" != null ] || die "deploy token creation failed"
  for e in prod-direct prod-mesh prod-windows; do echo "$user:$tok" > "$STATE/ctl-secrets/$e.token"; done
fi
chmod 700 "$STATE/ctl-secrets"; chmod 600 "$STATE/ctl-secrets/"*.token

say "CI -> controller SSH key (generated in-container: FIPS-host safe)"
if [ ! -f "$STATE/ci_ed25519" ]; then
  img=$(docker inspect --type container -f '{{.Config.Image}}' ansible-controller 2>/dev/null) || img=
  [ -n "$img" ] || img=ansible-controller:e2e
  docker run --rm -v "$PWD/$STATE":/w --entrypoint bash "$img" -euc \
    'ssh-keygen -q -t ed25519 -N "" -C "gitlab-ci->controller" -f /w/ci_ed25519; chown '"$(id -u):$(id -g)"' /w/ci_ed25519 /w/ci_ed25519.pub'
  chmod 600 "$STATE/ci_ed25519"
fi

say "authorized key (restricted to ctl-shell) in ./ssh/authorized_keys"
mkdir -p ssh && chmod 700 ssh
line="restrict,command=\"/usr/local/lab-bin/ctl-shell\" $(cat "$STATE/ci_ed25519.pub")"
grep -qsF "$(cat "$STATE/ci_ed25519.pub")" ssh/authorized_keys 2>/dev/null || echo "$line" >> ssh/authorized_keys
chmod 600 ssh/authorized_keys

say "controller->target key (./ssh/id_ed25519) + demo target's authorized_keys"
# prod-direct reaches the demo target as /home/ansible/.ssh/id_ed25519 (the
# controller's ./ssh mount). Generate it FIPS-safe if absent, and put its public
# half in the demo target's authorized_keys — gitlab/compose.gitlab.yml mounts
# .gitlab-state/target-ssh as that target's ~/.ssh — else Test case A fails with
# SSH authentication errors.
if [ ! -f ssh/id_ed25519 ]; then
  timg=$(docker inspect --type container -f '{{.Config.Image}}' ansible-controller 2>/dev/null) || timg=
  [ -n "$timg" ] || timg=ansible-controller:e2e
  docker run --rm -v "$PWD/ssh":/w --entrypoint bash "$timg" -euc \
    'ssh-keygen -q -t ed25519 -N "" -C "controller->target" -f /w/id_ed25519; chown '"$(id -u):$(id -g)"' /w/id_ed25519 /w/id_ed25519.pub'
  chmod 600 ssh/id_ed25519
fi
mkdir -p "$STATE/target-ssh" && chmod 700 "$STATE/target-ssh"
grep -qsF "$(cat ssh/id_ed25519.pub)" "$STATE/target-ssh/authorized_keys" 2>/dev/null \
  || cat ssh/id_ed25519.pub >> "$STATE/target-ssh/authorized_keys"
chmod 600 "$STATE/target-ssh/authorized_keys"

say "controller wiring (compose override) — start/refresh it now"
docker compose -f docker-compose.yml -f gitlab/controller.override.yml up -d --wait --no-build ansible
docker exec -u 0 ansible-controller sh -c 'chown ansible:ansible /var/lib/gitlab-runs 2>/dev/null || true'

say "pin the controller's host key (read from the container, not keyscan)"
hk=$(docker exec ansible-controller sh -c 'cut -d" " -f1,2 /etc/ssh/host_keys/ssh_host_ed25519_key.pub')
printf '%s %s\n' "$CTL_HOST" "$hk" > "$STATE/ctl-known-hosts"

say "protected CI variables CTL_SSH_KEY / CTL_KNOWN_HOSTS"
# scoped to this controller's environments (default prod-*): several
# controllers share one project by scoping channel variables per environment
ENV_SCOPE="${ENV_SCOPE:-prod-*}"
setvar() { glab DELETE "/projects/$PID/variables/$1?filter%5Benvironment_scope%5D=$(printf %s "$ENV_SCOPE" | sed s/\*/%2A/)" >/dev/null 2>&1 || true
  glab POST "/projects/$PID/variables" --data-urlencode "key=$1" \
    --data-urlencode "value@$2" --data-urlencode "variable_type=file" \
    --data-urlencode "protected=true" --data-urlencode "environment_scope=$ENV_SCOPE" >/dev/null; }
setvar CTL_SSH_KEY "$STATE/ci_ed25519"
setvar CTL_KNOWN_HOSTS "$STATE/ctl-known-hosts"
glab DELETE "/projects/$PID/variables/CTL_HOST?filter%5Benvironment_scope%5D=$(printf %s "$ENV_SCOPE" | sed s/\*/%2A/)" >/dev/null 2>&1 || true
glab POST "/projects/$PID/variables" --data-urlencode "key=CTL_HOST" \
  --data-urlencode "value=$CTL_HOST" --data-urlencode "protected=true" \
  --data-urlencode "environment_scope=$ENV_SCOPE" >/dev/null

say "runners (fresh bundled runner only; skipped when absent)"
RUNNER_CONTAINER="${RUNNER_CONTAINER:-gitlab-prod-runner}"
if docker inspect --type container "$RUNNER_CONTAINER" >/dev/null 2>&1; then
  JOB_NET="${GITLAB_NETWORK:-gitlab-prod_labnet}"
  reg() { # name tag access image extra...
    local n="$1" t="$2" a="$3" i="$4"; shift 4
    docker exec "$RUNNER_CONTAINER" sh -c "grep -q 'name = \"$n\"' /etc/gitlab-runner/config.toml 2>/dev/null" && return 0
    local tok
    tok=$(glab POST /user/runners --data-urlencode "runner_type=project_type" \
      --data-urlencode "project_id=$PID" --data-urlencode "description=$n" \
      --data-urlencode "tag_list=$t" --data-urlencode "access_level=$a" \
      --data-urlencode "locked=true" --data-urlencode "run_untagged=false" | jq -r .token)
    [ -n "$tok" ] && [ "$tok" != null ] || die "runner creation failed for $n"
    docker exec "$RUNNER_CONTAINER" gitlab-runner register --non-interactive \
      --url "http://${GITLAB_HOST:-gitlab.lab.local}:${GITLAB_PORT:-8929}" --token "$tok" --name "$n" \
      --executor docker --docker-image "$i" --docker-network-mode "$JOB_NET" \
      --docker-pull-policy if-not-present "$@" || die "runner registration failed for $n"
  }
  reg prod-validate mesh-validate not_protected "${VALIDATE_IMAGE:-ansible-controller:e2e}"
  # the deploy runner also runs the collect job (scripts/mesh-collect.sh), which
  # needs the controller's submission socket (/run/receptor) and job state
  # (/var/lib/mesh) — mount the same mesh volumes the disposable lab's deploy
  # runner gets. Project prefix = the controller compose project (dir basename
  # by default); override MESH_VOL_PREFIX if you renamed it.
  MESH_VOL_PREFIX="${MESH_VOL_PREFIX:-ansible-controller}"
  reg prod-deploy mesh-deploy ref_protected "${DEPLOY_IMAGE:-ansible-orchestrator:e2e}" \
    --docker-volumes "${MESH_VOL_PREFIX}_receptor-runtime:/run/receptor" \
    --docker-volumes "${MESH_VOL_PREFIX}_mesh-state:/var/lib/mesh"
else
  echo "    no $RUNNER_CONTAINER container — assuming an existing runner setup (e.g. the disposable lab's)"
fi

say "verify: SSH channel answers and refuses non-ctl-run commands"
net=$(docker inspect ansible-controller -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' | tr ' ' '\n' | grep -m1 labnet || die "controller is not on a gitlab network")
# the refusal itself exits non-zero — capture first so pipefail cannot
# turn the EXPECTED refusal into a false failure
vout=$(docker run --rm --network "$net" -v "$PWD/$STATE/ci_ed25519":/k:ro -v "$PWD/$STATE/ctl-known-hosts":/kh:ro \
  --entrypoint ssh "$(docker inspect --type container -f '{{.Config.Image}}' ansible-controller)" \
  -i /k -o UserKnownHostsFile=/kh -o StrictHostKeyChecking=yes -o BatchMode=yes \
  "ansible@$CTL_HOST" id 2>&1 || true)
grep -q "only invoke ctl-run" <<<"$vout" \
  && echo "    forced command active; channel up" \
  || die "SSH channel verification failed: $vout"
say "setup complete — environments: see $STATE/environments.yml"
