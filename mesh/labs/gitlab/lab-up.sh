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
avail_mem=$(awk '/MemAvailable/{print int($2/1024/1024)}' /proc/meminfo)
[ "$avail_mem" -ge 6 ] || die "need >=6 GiB available RAM for GitLab CE + mesh, have ${avail_mem} GiB"
avail_disk=$(df -BG --output=avail /var/lib/docker 2>/dev/null | tail -1 | tr -dc 0-9 || echo 0)
[ "${avail_disk:-0}" -ge 10 ] || die "need >=10 GB free under /var/lib/docker, have ${avail_disk} GB"
if ss -ltn 2>/dev/null | grep -q ':8929 '; then die "host port 8929 is already in use"; fi
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
if [ ! -f "$STATE/pat" ]; then
  PAT="glpat-$(openssl rand -hex 16)"
  docker exec gitlab-lab-gitlab gitlab-rails runner "
    u = User.find_by_username('root')
    t = u.personal_access_tokens.create!(scopes: ['api'], name: 'lab-bootstrap', expires_at: 30.days.from_now)
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
glab POST "/projects/$PID/members" \
  --data-urlencode "user_id=$DEV_ID" --data-urlencode "access_level=30" >/dev/null 2>&1 || true

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
reg_count=$(docker exec gitlab-lab-runner sh -c "grep -c '\\[\\[runners\\]\\]' /etc/gitlab-runner/config.toml 2>/dev/null" || echo 0)
if [ "${reg_count:-0}" -lt 2 ]; then
  # validate: no secrets, no sockets, no mesh volumes — safe for MR pipelines
  make_runner lab-validate mesh-validate not_protected ansible-controller:e2e
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
glab DELETE "/projects/$PID/protected_branches/main" >/dev/null 2>&1 || true
glab POST "/projects/$PID/protected_branches" \
  --data-urlencode "name=main" \
  --data-urlencode "push_access_level=0" \
  --data-urlencode "merge_access_level=40" \
  --data-urlencode "allow_force_push=false" >/dev/null
glab PUT "/projects/$PID" \
  --data-urlencode "only_allow_merge_if_pipeline_succeeds=true" \
  --data-urlencode "remove_source_branch_after_merge=true" >/dev/null
glab GET "/projects/$PID/variables/DEPLOY_ALLOWED" >/dev/null 2>&1 || \
  glab POST "/projects/$PID/variables" \
    --data-urlencode "key=DEPLOY_ALLOWED" --data-urlencode "value=true" \
    --data-urlencode "protected=true" >/dev/null

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
