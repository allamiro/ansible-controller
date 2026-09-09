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
# The state dir holds the highest-authority secrets (the root PAT, and lab.env
# with the GitLab root password) — make it owner-only and enforce 0600 on those
# files (the fresh-install steps have the operator drop them here).
chmod 700 "$STATE" 2>/dev/null || true
for f in "$STATE/pat" "$STATE/lab.env"; do [ -f "$f" ] && chmod 600 "$f"; done
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

# bootstrap PAT lifecycle: after wiring is complete, revoke it so the root-scoped
# api token does not linger. REVOKE_BOOTSTRAP=1 gitlab/setup.sh <url>
if [ "${REVOKE_BOOTSTRAP:-}" = 1 ]; then
  say "revoking the bootstrap PAT (self) and removing the local copy"
  if ! glab DELETE /personal_access_tokens/self >/dev/null; then
    die "PAT revocation failed; retained $PATF and curl credentials for retry or manual revocation"
  fi
  echo "    PAT revoked in GitLab"
  rm -f "$PATF" "$STATE/.curl-auth"
  exit 0
fi
ENC=$(printf %s "$PROJ" | sed 's|/|%2F|g')
if ! PID=$(glab GET "/projects/$ENC" 2>/dev/null | jq -r .id) || [ -z "$PID" ] || [ "$PID" = null ]; then
  say "project $PROJ absent — creating it (fresh-GitLab path)"
  # resolve the requested namespace so a nested path (e.g. platform/mesh-auto)
  # is created THERE, not silently under root (basename-only would do the latter,
  # then the group/path lookup below would never find it)
  ns=$(dirname "$PROJ"); pathseg=$(basename "$PROJ"); nsid=""
  if [ "$ns" != "." ]; then
    nsid=$(glab GET "/namespaces/$(printf %s "$ns" | sed 's|/|%2F|g')" 2>/dev/null | jq -r '.id // empty')
    [ -n "$nsid" ] || die "namespace '$ns' not found — create the group/user first, or use a path you own"
  fi
  glab POST /projects --data-urlencode "path=$pathseg" --data-urlencode "name=$pathseg" \
    ${nsid:+--data-urlencode "namespace_id=$nsid"} \
    --data-urlencode "visibility=private" --data-urlencode "initialize_with_readme=false" >/dev/null
  PID=$(glab GET "/projects/$ENC" | jq -r .id)
  [ -n "$PID" ] && [ "$PID" != null ] || die "project creation failed"
fi
# A prior attempt can create the project and fail before pushing the seed.
# Check GitLab's repository state independently of project creation.
project_state=$(glab GET "/projects/$ENC") || die "cannot inspect project repository state"
empty_repo=$(jq -r '.empty_repo' <<<"$project_state")
case "$empty_repo" in true|false) ;; *) die "GitLab returned no repository emptiness state";; esac
if [ "$empty_repo" = true ]; then
  say "seeding empty project $PROJ"
  seed=$(mktemp -d); cp -r mesh/labs/gitlab/project-seed/. "$seed/"
  # the seed pipeline ships lab-* environment names (the disposable lab runs
  # under them); this fresh path provisions prod-* CI variables, deploy tokens,
  # and env-map entries, so rewrite the seeded pipeline to the prod-* names it
  # will actually run under (else deploy jobs get no CTL_SSH_KEY by scope, or
  # ctl-run rejects an undefined environment)
  sed -i 's/\blab-direct\b/prod-direct/g; s/\blab-mesh\b/prod-mesh/g' "$seed/.gitlab-ci.yml"
  # Job images override the runner default. Bake operator choices into the
  # seed as literals so pipeline/trigger variables cannot select a new image.
  python3 - "$seed/.gitlab-ci.yml" "${VALIDATE_IMAGE:-ansible-controller:e2e}" "${DEPLOY_IMAGE:-ansible-controller:e2e}" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
pipeline = path.read_text()
for variable, image in zip(('VALIDATE_IMAGE', 'DEPLOY_IMAGE'), sys.argv[2:]):
    original = f'    name: ansible-controller:e2e # bootstrap: {variable}'
    if pipeline.count(original) != 1:
        raise SystemExit(f'expected one seed image marker for {variable}')
    pipeline = pipeline.replace(original, f'    name: {json.dumps(image)}')
path.write_text(pipeline)
PY
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

# Preserve a correct protection policy on reruns. Never delete protection:
# drift requires an administrator to reconcile it without an unprotected gap.
main_policy_matches() {
  jq -e '(.push_access_levels | length == 1 and .[0].access_level == 0)
    and (.merge_access_levels | length == 1 and .[0].access_level == 40)
    and (.allow_force_push == false)
    and ([.push_access_levels[], .merge_access_levels[]]
         | all(.user_id == null and .group_id == null and .deploy_key_id == null))' >/dev/null
}
protection=$(curl -sS -K "$STATE/.curl-auth" -w '\n%{http_code}' \
  "$GLURL/api/v4/projects/$PID/protected_branches/main") \
  || die "could not inspect main protection; existing policy left unchanged"
protection_code=$(tail -n 1 <<<"$protection")
case "$protection_code" in
  200)
    sed '$d' <<<"$protection" | main_policy_matches \
      || die "main protection differs from required policy; reconcile it in GitLab without removing protection, then rerun";;
  404)
    for attempt in 1 2 3; do
      if glab POST "/projects/$PID/protected_branches" --data-urlencode "name=main" \
        --data-urlencode "push_access_level=0" --data-urlencode "merge_access_level=40" \
        --data-urlencode "allow_force_push=false" >/dev/null; then
        break
      fi
      [ "$attempt" = 3 ] && die "failed to create main protection; protect main before using deployment jobs"
      sleep 3
    done;;
  *) die "main protection lookup returned HTTP $protection_code; existing policy left unchanged";;
esac
glab GET "/projects/$PID/protected_branches/main" | main_policy_matches \
  || die "main protection verification failed"
glab PUT "/projects/$PID" --data-urlencode "only_allow_merge_if_pipeline_succeeds=true" >/dev/null
# tag-deploy runs on the protected runner: releases need protected tags
if ! glab GET "/projects/$PID/protected_tags/v%2A" >/dev/null; then
  glab POST "/projects/$PID/protected_tags" --data-urlencode "name=v*" \
    --data-urlencode "create_access_level=40" >/dev/null \
    || die "protected release tag provisioning failed"
fi
glab GET "/projects/$PID/protected_tags/v%2A" | jq -e \
  '(.name == "v*") and (.create_access_levels | length == 1 and .[0].access_level == 40)
   and (.create_access_levels | all(.user_id == null and .group_id == null))' >/dev/null \
  || die "protected release tag policy verification failed"

say "environment map"
if [ ! -s "$STATE/environments.yml" ]; then
  python3 - "$PROJ" "$STATE/environments.yml" <<'PY'
import json
import sys
from pathlib import Path
# JSON-quoted strings are valid in YAML flow lists. Preserve the documented
# example and comments without requiring PyYAML on the bootstrap host.
example = Path('gitlab/environments.example.yml').read_text()
placeholder = '[root/mesh-automation]'
if placeholder not in example:
    sys.exit('environment template has no project placeholder')
Path(sys.argv[2]).write_text(example.replace(placeholder, json.dumps([sys.argv[1]])))
PY
fi

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

say "pipeline trigger token (for the seed pipeline's api-deploy job)"
# The seed pipeline ships an api-deploy job gated on CI_PIPELINE_SOURCE==trigger
# AND DEPLOY_CONFIRM==yes. Provision the trigger token it needs; it is a standing
# credential that can START pipelines (not run jobs), stored 0600. Delete it if
# you do not use external triggering:
#   curl -K "$STATE/.curl-auth" -X DELETE "$GLURL/api/v4/projects/$PID/triggers/<id>"
if [ ! -s "$STATE/trigger-token" ]; then
  tr=$(glab POST "/projects/$PID/triggers" --data-urlencode "description=ctl-api-trigger")
  ttok=$(jq -r .token <<<"$tr"); tid=$(jq -r .id <<<"$tr")
  if [ -n "$ttok" ] && [ "$ttok" != null ]; then
    (umask 077; printf '%s\n' "$ttok" > "$STATE/trigger-token")
    echo "    trigger token stored at $STATE/trigger-token (id $tid). Trigger a run with:"
    echo "      curl -X POST -F token=<trigger-token> -F ref=main -F variables[DEPLOY_CONFIRM]=yes \\"
    echo "        $GLURL/api/v4/projects/$PID/trigger/pipeline"
  else
    echo "    trigger token creation skipped (API returned none)"
  fi
fi

say "CI -> controller SSH key (generated in-container: FIPS-host safe)"
if [ ! -f "$STATE/ci_ed25519" ]; then
  img=$(docker inspect --type container -f '{{.Config.Image}}' ansible-controller 2>/dev/null) || img=
  [ -n "$img" ] || img=ansible-controller:e2e
  docker run --rm -v "$PWD/$STATE":/w --entrypoint bash "$img" -euc \
    'ssh-keygen -q -t ed25519 -N "" -C "gitlab-ci->controller" -f /w/ci_ed25519; chown '"$(id -u):$(id -g)"' /w/ci_ed25519 /w/ci_ed25519.pub'
  chmod 600 "$STATE/ci_ed25519"
fi

say "authorized key (restricted to ctl-shell) in ./ssh/authorized_keys"
# Write through the root container below: on reruns ssh/ is already owned by
# the container UID, which may differ from the host operator's UID.

say "controller->target key (./ssh/id_ed25519) + demo target's authorized_keys"
# prod-direct reaches the demo target as /home/ansible/.ssh/id_ed25519 (the
# controller's ./ssh mount). Generate it FIPS-safe if absent, and put its public
# half in the demo target's authorized_keys — gitlab/compose.gitlab.yml mounts
# .gitlab-state/target-ssh as that target's ~/.ssh — else Test case A fails with
# SSH authentication errors.
mkdir -p ssh "$STATE/target-ssh"
timg=$(docker inspect --type container -f '{{.Config.Image}}' ansible-controller 2>/dev/null) || timg=
[ -n "$timg" ] || timg=ansible-controller:e2e
# One root-in-container step so ownership is correct on ANY host uid: the key
# must be readable by the controller's ansible user (uid 1000), and the target's
# sshd StrictModes requires its ~/.ssh + authorized_keys owned by uid 1000. The
# CI authorized_keys (already written above) is re-owned to 1000 here too.
docker run --rm -u 0 -v "$PWD/ssh":/ctl -v "$PWD/$STATE/target-ssh":/tgt \
  -v "$PWD/$STATE/ci_ed25519.pub":/ci.pub:ro \
  --entrypoint bash "$timg" -euc '
    set -e
    ci_pub=$(cat /ci.pub)
    grep -qsF "$ci_pub" /ctl/authorized_keys 2>/dev/null || printf "restrict,command=\"/usr/local/lab-bin/ctl-shell\" %s\n" "$ci_pub" >> /ctl/authorized_keys
    [ -f /ctl/id_ed25519 ] || ssh-keygen -q -t ed25519 -N "" -C "controller->target" -f /ctl/id_ed25519
    pub=$(cat /ctl/id_ed25519.pub)
    grep -qsF "$pub" /tgt/authorized_keys 2>/dev/null || printf "%s\n" "$pub" >> /tgt/authorized_keys
    chown 1000:1000 /ctl /ctl/id_ed25519 /ctl/id_ed25519.pub /tgt /tgt/authorized_keys
    [ -f /ctl/authorized_keys ] && chown 1000:1000 /ctl/authorized_keys || true
    chmod 600 /ctl/authorized_keys /ctl/id_ed25519 /tgt/authorized_keys; chmod 700 /ctl /tgt'


say "controller wiring (compose override) — start/refresh it now"
# Preserve the active controller's overlays (especially its mesh image,
# sockets and state mounts). Rebuilding from the base file alone silently
# replaced a running orchestrator with the standalone service definition.
compose=(docker compose)
active_files=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' ansible-controller 2>/dev/null || true)
if [ -n "$active_files" ] && [ "$active_files" != '<no value>' ]; then
  active_project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' ansible-controller)
  compose+=(--project-name "$active_project")
  IFS=, read -r -a files <<< "$active_files"
  for file in "${files[@]}"; do
    [ -f "$file" ] || die "active controller Compose file missing: $file; restore it before wiring"
    compose+=(-f "$file")
  done
else
  docker inspect ansible-controller >/dev/null 2>&1 \
    && die "existing controller has no Compose file metadata; wire its definition explicitly"
  compose+=(-f docker-compose.yml)
fi
compose+=(-f "$PWD/gitlab/controller.override.yml")
"${compose[@]}" --profile '*' config --quiet
"${compose[@]}" --profile '*' up -d --wait --no-build --no-deps ansible
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
    if docker exec "$RUNNER_CONTAINER" sh -c "grep -q 'name = \"$n\"' /etc/gitlab-runner/config.toml 2>/dev/null"; then
      # Migrate registrations that previously exposed mesh authority to CI.
      local ok=1
      if [ "$n" = prod-deploy ]; then
        docker exec "$RUNNER_CONTAINER" awk '
          /\[\[runners\]\]/ { selected=0 }
          /name = "prod-deploy"/ { selected=1 }
          selected && /volumes.*(\/run\/receptor|\/var\/lib\/mesh)/ { bad=1 }
          END { exit bad }
        ' /etc/gitlab-runner/config.toml || ok=0
      fi
      local rid detail runner_code
      rid=$(docker exec "$RUNNER_CONTAINER" awk -v want="$n" '
        /\[\[runners\]\]/ { selected=0 }
        /^[[:space:]]*name[[:space:]]*=/ { gsub(/"/, ""); selected=($3 == want) }
        selected && /^[[:space:]]*id[[:space:]]*=/ { print $3; exit }
      ' /etc/gitlab-runner/config.toml)
      case "$rid" in *[!0-9]*|'') ok=0;;
        *)
          detail=$(curl -sS -K "$STATE/.curl-auth" -w '\n%{http_code}' "$GLURL/api/v4/runners/$rid") \
            || die "cannot verify existing runner $n; registration left unchanged"
          runner_code=$(tail -n 1 <<<"$detail")
          case "$runner_code" in
            404) ok=0;;
            200)
              sed '$d' <<<"$detail" | jq -e --arg access "$a" --arg tag "$t" --argjson pid "$PID" \
                '.paused == false and .access_level == $access and .locked == true
                 and .run_untagged == false and (.tag_list | index($tag) != null)
                 and (.projects | any(.id == $pid))' >/dev/null || ok=0;;
            *) die "runner lookup returned HTTP $runner_code; registration left unchanged";;
          esac;;
      esac
      [ "$ok" = 1 ] && return 0
      echo "    $n has stale policy or legacy mesh mounts — re-registering"
      docker exec "$RUNNER_CONTAINER" gitlab-runner unregister --name "$n" >/dev/null 2>&1 \
        || die "cannot remove stale registration $n; reconcile its local runner config before retrying (no duplicate registered)"
    fi
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
  # Both dispatch and collection go through ctl-run over SSH. CI jobs must
  # not receive direct submission authority or controller state volumes.
  reg prod-deploy mesh-deploy ref_protected "${DEPLOY_IMAGE:-ansible-controller:e2e}"

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
