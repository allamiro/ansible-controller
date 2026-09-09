# GitLab CE alongside the Ansible controller

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
| Single-box node | [`node.local.yml`](node.local.yml) | one execution node on this box, dialing the host's 27199/27200 — the mesh test case |
| Bootstrap | [`setup.sh`](setup.sh) | tokens, keys, CI variables, project wiring — idempotent |

Site state (tokens, keys, your real `environments.yml`) lives in
`gitlab/.gitlab-state/` — gitignored, per box.

## Test case A — GitLab + controller, single (standalone) mode

```bash
# 1. GitLab: reuse a running instance, or start one:
#      docker compose --env-file gitlab/.gitlab-state/lab.env -f gitlab/compose.gitlab.yml up -d --wait
# 2. create the environment map FIRST — the controller override binds it
#    read-only and refuses to start if it is missing (setup.sh refreshes it):
mkdir -p gitlab/.gitlab-state
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

## Test case B — GitLab + controller + one mesh node on this box

```bash
# 1. mesh PKI (real scripts; throwaway CA is fine on a test box):
mesh/pki/mesh-ca-init.sh "local test CA"
mesh/pki/work-sign-init.sh
# the node dials the ingresses as ${MESH_PEER_HOST:-host.docker.internal}; that
# name MUST be a DNS SAN on the ingress certs or receptor's hostname check fails
# (ARCHITECTURE.md §5 records this exact rejection). Pass it as an extra SAN:
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
# the env map must exist before the controller override binds it (see case A):
mkdir -p gitlab/.gitlab-state
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

**CE honesty**: merge-request approvals are optional in CE (approval RULES
are Premium). The enforced controls are protected branches
(merge=Maintainers, push=no one), pipelines-must-succeed, protected
runners/variables, and manual jobs. Do not represent the manual button as
multi-person approval enforcement.

## Trust boundaries (summary)

| Connection | Initiator | Auth / verification |
|---|---|---|
| Runner → GitLab | runner (outbound HTTP/S) | per-runner token; TLS per your GitLab install |
| CI job → controller | job container (SSH 22, in-network) | ed25519 key (protected file variable), host key PINNED, forced command `ctl-shell` |
| ctl-run → GitLab | controller (outbound HTTP/S) | read-only deploy token, held on the controller only |
| orchestrator → ingress | local Unix socket | filesystem permissions = submission authority |
| node → ingress | node (outbound TCP 27199/27200) | mesh mTLS + node-ID SAN binding + signed work |
| controller/node → targets | executing runtime | SSH keys / WinRM (HTTPS+validation preferred); host-key & CA trust live where Ansible runs |

Honest scope notes: the `ansible` account on the controller has broad
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
