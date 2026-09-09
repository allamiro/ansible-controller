# GitLab CE alongside the Ansible controller

For a screen-by-screen walkthrough, start with [GitLab CE: from first login to Ansible results](STEP-BY-STEP.md).

Start with the [operator and Maintainer walkthrough](MAINTAINER-README.md)
for login, project creation, controller connections, review, deployment approval,
updates and recovery. **The standard workflow uses GitLab Community Edition
and requires no Premium license.**

![GitLab Community Edition deployment workflow](diagrams/workflow.svg)

Current test results and known limits: [VERIFICATION.md](VERIFICATION.md).
The isolated audit suite is in [tests/README.md](tests/README.md).

This directory makes **GitLab CE the everyday interface** for the controller
on the same box: projects, branches, merge requests, reviewed merges, and
pipelines that request controller execution of a specific commit —
standalone (controller → SSH/WinRM → targets) or through the mesh
(orchestrator → Receptor → node → SSH/WinRM → targets).

It adds **no service and no API**. One command is the whole integration:
[`bin/ctl-run`](bin/ctl-run) runs **on the controller**, fetches an exact
requested commit from GitLab, and executes it through the engines that
already exist (`ansible-playbook`, `mesh/bin/mesh-run`). CI reaches it over
SSH with a key that can invoke *only this command*
([`bin/ctl-shell`](bin/ctl-shell) forced command).

GitLab is optional. The controller **pulls** project content; the Runner job
sends an SSH execution request, and neither GitLab nor its jobs contact mesh
execution nodes directly. The existing native `make run`, `make mesh-run` and
`make mesh-collect` workflows continue to work without GitLab using local
project files. See the [architecture boundary](ARCHITECTURE.md#required-boundary-gitlab-is-optional).

| Piece | File | Role |
|---|---|---|
| GitLab CE + Runner | [`compose.gitlab.yml`](compose.gitlab.yml) | fresh single-box GitLab install (skip if you already run one) |
| Controller wiring | [`controller.override.yml`](controller.override.yml) | mounts ctl-run + env map + secrets into the EXISTING `ansible` service and joins it to the GitLab network |
| Environment map | [`environments.example.yml`](environments.example.yml) | administrator-owned: which env may run which projects, in which mode, against what |
| Single-box node | [`node.local.yml`](node.local.yml) | one execution node on this box, dialing the host's 27199/27200 for mesh execution |
| Bootstrap | [`setup.sh`](setup.sh) | tokens, keys, CI variables, project wiring — idempotent |

Site state (tokens, keys, your real `environments.yml`) lives in
`gitlab/.gitlab-state/` — gitignored, per box.

Set `VALIDATE_IMAGE` and `DEPLOY_IMAGE` when running `setup.sh` to choose the
validation and SSH deployment job images (both default to
`ansible-controller:e2e`). For an empty project, setup writes these choices
as literal images into the seeded pipeline as well as the runner defaults.
Validation images need Ansible and ansible-lint; deployment images need Git
and an SSH client. Setup preserves populated repositories: update their
`validate.image.name` and `.ctl-ssh.image.name` through a reviewed commit
when changing images. Pipeline variables do not select these job images.

## Standalone setup

```bash
# 1. GitLab: reuse a running instance, or start one:
#      docker compose --env-file gitlab/.gitlab-state/lab.env -f gitlab/compose.gitlab.yml up -d --wait
# 2. create the environment map and private token directory FIRST — the
#    override refuses missing bind sources. setup.sh preserves an existing map;
#    set allowed_projects to your chosen project if it differs from the example.
mkdir -p gitlab/.gitlab-state/ctl-secrets
chmod 700 gitlab/.gitlab-state gitlab/.gitlab-state/ctl-secrets
cp -n gitlab/environments.example.yml gitlab/.gitlab-state/environments.yml
# 3. wire the controller into the GitLab network with ctl-run aboard:
docker compose -f docker-compose.yml -f gitlab/controller.override.yml up -d
# 4. bootstrap (project, runner wiring, keys, env map, CI variables):
gitlab/setup.sh http://localhost:8929
# 5. from a pipeline (or by hand over the same channel):
#      ssh -i <ci-key> ansible@ctl.prod.local \
#        ctl-run --env prod-direct --project root/mesh-automation \
#                --sha <reviewed-40-hex> --playbook playbooks/site.yml
```

Execution path: GitLab Runner job → SSH (pinned host key, forced command)
→ `ctl-run` on the controller → fetch commit from GitLab (read-only deploy
token held on the controller) → `ansible-playbook` → SSH/WinRM targets the
controller can reach. Results: the playbook's real exit code is the CI
job's status.

## Mesh setup

```bash
# 1. mesh PKI (real scripts; throwaway CA is fine on a test box):
mesh/pki/mesh-ca-init.sh "local test CA"
mesh/pki/work-sign-init.sh
# the node dials the ingresses as ${MESH_PEER_HOST:-host.docker.internal}; that
# name MUST be a DNS SAN on the ingress certs or receptor's hostname check fails
# See ARCHITECTURE.md for certificate trust. Pass it as an extra SAN:
mesh/pki/controller-cert.sh controller-a receptor-controller "${MESH_PEER_HOST:-host.docker.internal}"
mesh/pki/controller-cert.sh controller-b receptor-controller-b "${MESH_PEER_HOST:-host.docker.internal}"
mesh/pki/node-csr.sh exec-local-a && mesh/pki/node-sign.sh csr/exec-local-a.csr exec-local-a
cp mesh/secrets/receptor/csr/exec-local-a.key mesh/secrets/receptor/issued/exec-local-a/tls.key
chmod 600 mesh/secrets/receptor/issued/exec-local-a/tls.key
sudo chown -R 1000:1000 mesh/secrets/receptor/issued/exec-local-a

# 2. control plane (orchestrator image + both ingresses on host 27199/27200):
#    orchestrator.override.yml must point the ansible service at an
#    orchestrator image (see mesh/README Step 2)
make mesh-up
# The env map and operator-owned token directory must exist first (see case A):
mkdir -p gitlab/.gitlab-state/ctl-secrets
chmod 700 gitlab/.gitlab-state gitlab/.gitlab-state/ctl-secrets
cp -n gitlab/environments.example.yml gitlab/.gitlab-state/environments.yml
docker compose -f docker-compose.yml -f gitlab/controller.override.yml -f mesh/compose.mesh.yml --profile mesh up -d

# 3. the local node — dials the HOST's published ports, like a remote node would:
docker compose -f gitlab/node.local.yml up -d --wait
docker exec ansible-controller receptorctl --socket /run/receptor/receptor.sock status | grep exec-local-a

# 4. run through GitLab exactly as in case A, environment prod-mesh:
#      ctl-run --env prod-mesh --project ... --sha ... --playbook playbooks/ping.yml
```

Execution path: CI job → SSH → `ctl-run` → fetch → `mesh-run` → ingress
Unix socket → signed work over mTLS → `exec-local-a` → SSH/WinRM targets in
the node's network. Never-run-twice, `results-incomplete`, `--collect`
recovery, and slot admission all apply unchanged — `ctl-run` adds a
per-environment lock and refuses to dispatch while any tracked mesh job is
non-final (the CI-retry guard).

## The everyday GitLab workflow

Branch → change playbooks/inventory → MR (validation pipeline: syntax +
lint, no deploy authority) → review → Maintainer merges to protected main
→ pipeline offers manual `deploy-*` jobs → a human releases one → the
target records the deployed commit. Recovery (`collect`), schedules,
API-triggered and tag-driven runs: see the pipeline templates in the seed
project of the disposable lab (`mesh/labs/gitlab/project-seed/`), which
exercises this exact integration end to end.

**Community Edition controls:** merge-request approval is recorded but optional.
The enforced controls are protected branches
(merge=Maintainers, push=no one), pipelines-must-succeed, protected
runners/variables, and manual jobs. Do not represent the manual button as
required reviewer counts.

## CI approval, retries and artifacts

The reference is [project-seed/.gitlab-ci.yml](../mesh/labs/gitlab/project-seed/.gitlab-ci.yml)
and its [scripts/ctl-ci.sh](../mesh/labs/gitlab/project-seed/scripts/ctl-ci.sh).
Every dispatch route, including schedules and API triggers, requires a manual
release. CE uses protected `main`/`v*`, a protected runner and protected file
variables. Maintainers review and merge changes, then release deployment jobs.
This workflow does not need native protected environments or required approval
rules. [Optional licensed approval policies](OPTIONAL-APPROVALS.md) are separate.

`ctl-run --pipeline N` identifies one logical request by controller environment,
project, pipeline ID and playbook path, and binds that request to its commit.
Changing the GitLab job ID on Retry does not change the request. Under the
environment lock, the controller durably claims it **before** execution:

| Retry state | Behavior |
|---|---|
| Completed success or failure | Return the recorded playbook exit code without executing again |
| Recorded pre-submission refusal | Allow another admission attempt; no work had been submitted |
| Started, interrupted or ambiguous | Refuse another execution; collect/reconcile the original mesh UUID |
| Original mesh job subsequently collected | Read authoritative mesh metadata and return its recovered exit code |
| Same request with a different commit | Refuse the conflicting request |

This is host-local request deduplication, not distributed exactly-once execution.
Keep `/var/lib/gitlab-runs/requests/` and corresponding records on persistent
storage; deleting claims removes retry protection. Do not prune unresolved
requests. A **new pipeline** is a new deliberate execution; rerunning a schedule
is also a new pipeline. Callers omitting `--pipeline` retain native per-invocation
behavior. Changing environment/project/playbook creates a different request.
For an interrupted standalone run, inspect the controller/target and reconcile
manually; there is no mesh collection command for standalone execution.

`scripts/ctl-ci.sh` exports through `ctl-run --artifacts` over the same pinned,
forced-command SSH connection. GitLab uploads `mesh-artifacts/` with `when:
always`, seven-day expiry, and Maintainer download access. Open a deployment
job's **Browse artifacts** to inspect `ctl-run.json`, `console.log` when present,
and `logs/runner/<uuid>/meta.json`, stdout, rc/status and JSON job events when
available. The exporter whitelists result files; it does not expose the fetched
tree, private keys, mesh environment or arbitrary paths. Results can still
contain playbook output: use Ansible `no_log` for sensitive tasks and keep the
project private. See [GitLab job artifacts](https://docs.gitlab.com/ci/jobs/job_artifacts/).

Failed playbook exit codes survive export failures. If execution succeeds but
required export fails, the CI job exits 2 and reports the export error; Retry
replays the original execution result and attempts export again. A hard job
cancellation may prevent artifact upload: retry the same job or use `collect`
with `JOB_ID` for an incomplete mesh result. `collect` also exports artifacts
and never dispatches a new playbook. The runner still holds no mesh TLS keys.

Existing GitLab repositories are not overwritten by setup. Upgrade both their
pipeline and `scripts/ctl-ci.sh` through review (retaining your `prod-*` names),
and deploy the complete `gitlab/bin/` directory on the controller. Old requests
from before this journal existed cannot be deduplicated retroactively.

## Trust boundaries (summary)

| Connection | Initiator | Auth / verification |
|---|---|---|
| Runner → GitLab | runner (outbound HTTP/S) | per-runner token; TLS per your GitLab install |
| CI job → controller | job container (SSH 22, in-network) | ed25519 key (protected file variable), host key PINNED, forced command `ctl-shell` |
| ctl-run → GitLab | controller (outbound HTTP/S) | read-only deploy token, held on the controller only |
| orchestrator → ingress | local Unix socket | filesystem permissions = submission authority |
| node → ingress | node (outbound TCP 27199/27200) | mesh mTLS + node-ID SAN binding + signed work |
| controller/node → targets | executing runtime | SSH keys / WinRM (HTTPS+validation preferred); host-key & CA trust live where Ansible runs |

The `ansible` account on the controller has broad
privileges by design — the forced command narrows what *this SSH key* can
invoke, not what the account could do; and `ctl-run` validates inputs and
stages safely but does not sandbox playbook content — trusted authorship
via protected branches is the control for that. GitLab TLS choices (public
CA / internal CA / self-signed / reverse proxy / lab HTTP) affect the
GitLab hops only and never replace mesh mTLS; see
`mesh/labs/gitlab/README.md` for the full matrix and lifecycle evidence.

## Private-CA project fetch

Mount the GitLab CA bundle read-only on the controller and set
`git_ca_file: /path/inside/controller/ca.pem` in its administrator-owned
environment mapping. `ctl-run` sets Git's CA path after the SSH/sudo boundary;
it does not depend on forwarding environment variables from CI. Continue to
verify the URL hostname. Configure the Runner manager and checkout helper's
trust separately, and configure WinRM trust at the executing runtime separately.

Run staging is retained for investigation. Apply an operator-owned retention
policy that preserves unresolved runs and required audit evidence, and monitor
the `/var/lib/gitlab-runs` volume's disk use.

Standalone execution restores `/configs/ansible.cfg` after the SSH/sudo boundary
when that site file exists and `ANSIBLE_CONFIG` is unset. An explicit
administrator-provided `ANSIBLE_CONFIG` takes precedence; without either,
Ansible discovers the fetched project's configuration from its root directory.
Mesh execution stages the full fetched repository with `mesh-run --project-dir`,
preserving nested playbook paths and root-level roles, collections and config.
Paths inside that config must still be valid on the execution node.

Standalone execution also restores `/home/ansible/.vault_pass` as the Vault
password file after sudo when no explicit `ANSIBLE_VAULT_PASSWORD_FILE` is set.
The controller entrypoint creates that private file from either supported Vault
source. Mesh nodes still need their own separately provisioned Vault material.

Bootstrap leaves matching branch protection in place. If an existing policy
differs, setup fails and asks the administrator to reconcile it in GitLab;
it never removes protection as part of a rerun. Seed deployment jobs use the
actual Runner checkout's commit, so overriding `CI_COMMIT_SHA` in trigger
variables cannot select a different deployment commit.

Mesh console logs are streamed to private files under
`/var/lib/gitlab-runs/logs/`; include them in the operator's retention policy.
Bootstrap seeds an existing empty repository after an interrupted initial
attempt, verifies release-tag protection, and checks runner registrations
against GitLab before accepting them. If a stale registration cannot be removed,
setup fails with a reconciliation instruction instead of registering duplicates.
These checks use GitLab's [project repository state](https://docs.gitlab.com/api/projects/)
and [runner details API](https://docs.gitlab.com/api/runners/).

For target usernames/passwords, Vault provisioning and protected release tags,
follow [the deployment credential walkthrough](MAINTAINER-README.md#save-deployment-credentials-and-release-a-version).
