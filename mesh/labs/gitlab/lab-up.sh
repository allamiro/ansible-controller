#!/bin/bash
# Stand up the complete GitLab CE + mesh integration lab:
#   1. pre-flight resource checks
#   2. the repository's disposable mesh e2e environment (throwaway CA, mTLS,
#      signed work, execution node, isolated SSH target)
#   3. GitLab CE 19.3 + gitlab-runner (compose project "gitlab-lab")
#   4. bootstrap: root PAT, dev user, project, protected branch, merge checks,
#      protected variable, one unprotected validate runner + one ref_protected
#      deploy runner, and the seed repository pushed to main
#
# Usage: mesh/labs/gitlab/lab-up.sh [controller-image]
#   controller-image defaults to the published release image; any local
#   controller image tag works (mesh/tests/e2e-up.sh builds the mesh images
#   from it).
#
# Idempotent-ish: safe to re-run after a failed boot; lab-down.sh gives a
# clean slate. State (passwords, tokens, URLs) lands in .lab-state/ beside
# this script — gitignored, disposable.
set -euo pipefail
cd "$(dirname "$0")/../../.."   # repository root
LAB="mesh/labs/gitlab"
# Runner registrations and volume mounts below reference resources by the
# compose files' pinned project names (gitlab-lab, mesh-e2e); an inherited
# COMPOSE_PROJECT_NAME would re-prefix everything and break those references.
unset COMPOSE_PROJECT_NAME
STATE="$LAB/.lab-state"
CONTROLLER_IMAGE="${1:-ghcr.io/allamiro/ansible-controller:0.23.3}"   # image tags carry no v prefix
GITLAB_URL_HOST="http://localhost:8929"          # operator/seed-push view
GITLAB_URL_LAB="http://gitlab.lab.local:8929"    # runner/job-container view

say()  { printf '\n==> %s\n' "$*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
glab() { # method path [curl args...] — authenticated API call as root
  local m="$1" p="$2"; shift 2
  curl -sfS -X "$m" -H "PRIVATE-TOKEN: $PAT" "$GITLAB_URL_HOST/api/v4$p" "$@"
}

say "pre-flight"
command -v docker >/dev/null || die "docker is required"
docker compose version >/dev/null 2>&1 || die "docker compose v2 is required"
for t in jq curl openssl git ss; do
  command -v "$t" >/dev/null || die "'$t' is required on the host (bootstrap uses it)"
done
avail_mem=$(awk '/MemAvailable/{print int($2/1024/1024)}' /proc/meminfo)
[ "$avail_mem" -ge 6 ] || die "need >=6 GiB available RAM for GitLab CE + mesh, have ${avail_mem} GiB"
avail_disk=$(df -BG --output=avail /var/lib/docker 2>/dev/null | tail -1 | tr -dc 0-9 || echo 0)
[ "${avail_disk:-0}" -ge 10 ] || die "need >=10 GB free under /var/lib/docker, have ${avail_disk} GB"
# port conflict check — but a rerun over THIS lab's own GitLab is fine (the
# bootstrap below is idempotent and must be reachable after a partial run)
if ss -ltn 2>/dev/null | grep -q ':8929 ' \
   && ! docker ps --format '{{.Names}}' | grep -qx gitlab-lab-gitlab; then
  die "host port 8929 is in use by something other than this lab"
fi
mkdir -p "$STATE"

say "mesh half: disposable e2e environment from ${CONTROLLER_IMAGE}"
docker image inspect "$CONTROLLER_IMAGE" >/dev/null 2>&1 || docker pull "$CONTROLLER_IMAGE"
mesh/tests/e2e-up.sh "$CONTROLLER_IMAGE"

say "GitLab half: compose project gitlab-lab"
if [ ! -f "$STATE/lab.env" ]; then
  {
    echo "LAB_ROOT_PASSWORD=Lab-$(openssl rand -hex 12)"
    echo "LAB_DEV_PASSWORD=Dev-$(openssl rand -hex 12)"
  } > "$STATE/lab.env"
  chmod 600 "$STATE/lab.env"
fi
# shellcheck disable=SC1091
. "$STATE/lab.env"
export LAB_ROOT_PASSWORD
# FIPS-host workaround (see compose.gitlab.yml): mask fips_enabled inside the
# disposable GitLab container only.
echo 0 > "$STATE/fips0"
docker compose --env-file "$STATE/lab.env" -f "$LAB/compose.gitlab.yml" up -d --wait \
  || die "GitLab stack failed to become healthy — docker logs gitlab-lab-gitlab"

say "root personal access token (rails console — first boot only)"
pat_valid() { [ -f "$STATE/pat" ] && PAT=$(cat "$STATE/pat") && glab GET /user >/dev/null 2>&1; }
if ! pat_valid; then
  # No token yet, or a stale one from before a lab-down wiped the GitLab
  # volumes — mint a fresh one either way.
  rm -f "$STATE/pat"
  PAT="glpat-$(openssl rand -hex 16)"
  docker exec gitlab-lab-gitlab gitlab-rails runner "
    u = User.find_by_username('root')
    t = u.personal_access_tokens.create!(scopes: ['api'], name: 'lab-bootstrap-$(date +%s)', expires_at: 30.days.from_now)
    t.set_token('$PAT'); t.save!
  " || die "PAT creation failed"
  (umask 077 && echo "$PAT" > "$STATE/pat")
fi
PAT=$(cat "$STATE/pat")
glab GET /user >/dev/null || die "PAT does not authenticate"

say "developer user (MR author; cannot merge to protected main)"
if ! glab GET "/users?username=dev1" | grep -q '"username":"dev1"'; then
  glab POST /users \
    --data-urlencode "email=dev1@lab.local" --data-urlencode "username=dev1" \
    --data-urlencode "name=Lab Developer" --data-urlencode "password=$LAB_DEV_PASSWORD" \
    --data-urlencode "skip_confirmation=true" >/dev/null
fi
DEV_ID=$(glab GET "/users?username=dev1" | jq -r '.[0].id')

say "project mesh-automation"
if ! glab GET "/projects/root%2Fmesh-automation" >/dev/null 2>&1; then
  glab POST /projects --data-urlencode "name=mesh-automation" \
    --data-urlencode "visibility=private" \
    --data-urlencode "initialize_with_readme=false" >/dev/null
fi
PID=$(glab GET "/projects/root%2Fmesh-automation" | jq -r .id)
# add-or-tolerate-existing, then VERIFY: a swallowed transient failure here
# would surface later as inexplicable dev1 permission errors
glab POST "/projects/$PID/members" \
  --data-urlencode "user_id=$DEV_ID" --data-urlencode "access_level=30" >/dev/null 2>&1 || true
lvl=$(glab GET "/projects/$PID/members/all/$DEV_ID" 2>/dev/null | jq -r '.access_level // 0')
if [ "$lvl" != 30 ]; then
  # EXACTLY Developer: a leftover Maintainer grant from experimentation
  # would let dev1 merge to protected main, silently voiding the lab's
  # review gate on reruns
  glab PUT "/projects/$PID/members/$DEV_ID" --data-urlencode "access_level=30" >/dev/null \
    || die "dev1 must be exactly a Developer (found access_level=$lvl) and could not be set"
fi

say "runners: validate (unprotected) + deploy (ref_protected)"
make_runner() { # description tag access_level image extra_volume_args...
  local desc="$1" tag="$2" access="$3" image="$4"; shift 4
  local tok
  tok=$(glab POST /user/runners \
    --data-urlencode "runner_type=project_type" --data-urlencode "project_id=$PID" \
    --data-urlencode "description=$desc" --data-urlencode "tag_list=$tag" \
    --data-urlencode "access_level=$access" --data-urlencode "locked=true" \
    --data-urlencode "run_untagged=false" | jq -r .token)
  [ -n "$tok" ] && [ "$tok" != null ] || die "runner creation failed for $desc"
  docker exec gitlab-lab-runner gitlab-runner register --non-interactive \
    --url "$GITLAB_URL_LAB" --token "$tok" --name "$desc" \
    --executor docker --docker-image "$image" \
    --docker-network-mode gitlab-lab_labnet \
    --docker-pull-policy if-not-present "$@" \
    || die "runner registration failed for $desc"
}
# Each REQUIRED registration is checked by name locally AND against GitLab —
# a config.toml entry whose runner was deleted/paused/re-leveled server-side
# would otherwise satisfy a local-only check while jobs hang or, worse, a
# deploy runner made unprotected serves branch pipelines.
runner_registered() { # name expected-access-level
  docker exec gitlab-lab-runner sh -c "grep -q 'name = \"$1\"' /etc/gitlab-runner/config.toml 2>/dev/null" || return 1
  local rid det
  rid=$(glab GET "/projects/$PID/runners?per_page=100" | jq -r "[.[] | select(.description==\"$1\")][0].id // empty")
  [ -n "$rid" ] || return 1
  det=$(glab GET "/runners/$rid") || return 1
  jq -e ".paused == false and .access_level == \"$2\"" <<<"$det" >/dev/null || return 1
}
drop_runner() { docker exec gitlab-lab-runner gitlab-runner unregister --name "$1" >/dev/null 2>&1 || true; }
if ! runner_registered lab-validate not_protected; then
  drop_runner lab-validate
  # validate: no secrets, no sockets, no mesh volumes — safe for MR pipelines
  make_runner lab-validate mesh-validate not_protected ansible-controller:e2e
fi
if ! runner_registered lab-deploy ref_protected; then
  drop_runner lab-deploy
  # deploy: ref_protected; job containers get ONLY the three mesh volumes.
  # /run/receptor = submission authority; /var/lib/mesh = job state (so the
  # no-resubmission guard and collect work); /e2e-ssh = the disposable key.
  make_runner lab-deploy mesh-deploy ref_protected ansible-orchestrator:e2e \
    --docker-volumes mesh-e2e_receptor-runtime:/run/receptor \
    --docker-volumes mesh-e2e_mesh-state:/var/lib/mesh \
    --docker-volumes mesh-e2e_e2e-ssh:/e2e-ssh:ro
fi

say "seed repository -> main (before protection is tightened)"
if ! glab GET "/projects/$PID/repository/branches/main" >/dev/null 2>&1; then
  seed=$(mktemp -d)
  cp -r "$LAB/project-seed/." "$seed/"
  git -C "$seed" init -q -b main
  git -C "$seed" -c user.name="Lab Operator" -c user.email="lab@lab.local" add -A
  git -C "$seed" -c user.name="Lab Operator" -c user.email="lab@lab.local" \
    commit -qm "seed: mesh automation project (validate + gated mesh deploy)"
  git -C "$seed" push -q "http://root:$PAT@localhost:8929/root/mesh-automation.git" main
  rm -rf "$seed"
fi

say "enforcement: protected main (push=no one, merge=maintainers) + merge checks + protected variable"
# Never delete-then-recreate: a failure between the two would leave main
# unprotected, and even success opens a brief writable window on reruns.
prot=$(glab GET "/projects/$PID/protected_branches/main" 2>/dev/null || echo '{}')
# the WHOLE policy must match to skip: exactly one push level (0), exactly
# one merge level (40), and force pushes off — a partial match could leave
# extra actors or force pushes permitted from an earlier partial run
if ! jq -e '(.push_access_levels | length == 1 and .[0].access_level == 0)
            and (.merge_access_levels | length == 1 and .[0].access_level == 40)
            and (.allow_force_push == false)' <<<"$prot" >/dev/null; then
  # The policy is absent or WRONG (extra principals, force push, ...).
  # PATCH cannot help here: it APPENDS access entries rather than replacing
  # extras, so a drifted policy must be recreated. The brief unprotected
  # window exists only in this already-wrong state; the POST is retried and
  # a persistent failure aborts LOUDLY rather than leaving main silently
  # open. The exact-match rerun path above never enters this branch.
  if [ "$(jq -r '.name // empty' <<<"$prot")" = main ]; then
    glab DELETE "/projects/$PID/protected_branches/main" >/dev/null
  fi
  for attempt in 1 2 3; do
    if glab POST "/projects/$PID/protected_branches" \
      --data-urlencode "name=main" \
      --data-urlencode "push_access_level=0" \
      --data-urlencode "merge_access_level=40" \
      --data-urlencode "allow_force_push=false" >/dev/null; then
      break
    fi
    [ "$attempt" = 3 ] && die "FAILED to protect main after 3 attempts — main is currently UNPROTECTED; re-run lab-up.sh or protect it in the UI before using the lab"
    sleep 3
  done
fi
# post-condition, whichever path ran: the exact policy is in force
glab GET "/projects/$PID/protected_branches/main" | jq -e \
  '(.push_access_levels | length == 1 and .[0].access_level == 0)
   and (.merge_access_levels | length == 1 and .[0].access_level == 40)
   and (.allow_force_push == false)' >/dev/null \
  || die "main protection verification failed"
glab PUT "/projects/$PID" \
  --data-urlencode "only_allow_merge_if_pipeline_succeeds=true" \
  --data-urlencode "remove_source_branch_after_merge=true" >/dev/null
# create-or-reconcile: wrong value fails every deploy's tripwire, an
# unprotected one leaks to branch pipelines, and a narrowed environment
# scope silently hides it from the deploy job. Anything off → recreate
# with the exact shape (a variable, unlike branch protection, has no
# dangerous unconfigured window).
dv=$(glab GET "/projects/$PID/variables/DEPLOY_ALLOWED" 2>/dev/null || echo '{}')
if ! jq -e '.value == "true" and .protected == true and .environment_scope == "*"' <<<"$dv" >/dev/null; then
  [ "$(jq -r '.key // empty' <<<"$dv")" = DEPLOY_ALLOWED ] && \
    glab DELETE "/projects/$PID/variables/DEPLOY_ALLOWED" >/dev/null 2>&1 || true
  glab POST "/projects/$PID/variables" \
    --data-urlencode "key=DEPLOY_ALLOWED" --data-urlencode "value=true" \
    --data-urlencode "protected=true" --data-urlencode "environment_scope=*" >/dev/null
fi

cat > "$STATE/summary" <<SUMMARY
GitLab      : $GITLAB_URL_HOST   (root / see $STATE/lab.env)
Dev user    : dev1 / see $STATE/lab.env (Developer on root/mesh-automation)
Project     : $GITLAB_URL_HOST/root/mesh-automation
Runners     : lab-validate (tag mesh-validate, unprotected)
              lab-deploy   (tag mesh-deploy, PROTECTED refs only)
Mesh        : compose project mesh-e2e (node exec-e2e-a, target mesh-e2e-target)
Teardown    : mesh/labs/gitlab/lab-down.sh
SUMMARY
say "lab is up"
cat "$STATE/summary"
