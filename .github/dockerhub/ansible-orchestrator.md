<p align="center">
<a href="https://buymeacoffee.com/pcileky2q"><img src="https://raw.githubusercontent.com/allamiro/ansible-controller/main/assets/support/buy-me-a-coffee.svg" alt="Buy Me a Coffee" height="56"></a>
&nbsp;&nbsp;
<a href="https://github.com/sponsors/allamiro"><img src="https://raw.githubusercontent.com/allamiro/ansible-controller/main/assets/support/github-sponsors.svg" alt="Sponsor on GitHub" height="56"></a>
</p>

# Ansible Orchestrator

[Project overview](https://github.com/allamiro/ansible-controller) · [Contact](mailto:tsuliman@linuxvaults.com?subject=Ansible%20Controller%20support%20enquiry) · [Support terms](https://github.com/allamiro/ansible-controller/blob/main/SUPPORT.md)

The [Ansible Controller](https://hub.docker.com/r/allamiro1/ansible-controller) **plus the
distributed-execution dispatcher**. Use it in place of the controller on your control host
when some targets live in networks the controller cannot route to — DMZs, OT segments,
isolated VLANs, remote sites. You keep running playbooks exactly as before; when a target
sits behind a wall, `mesh-run` hands the job to the
[execution node](https://hub.docker.com/r/allamiro1/ansible-execution-node) inside that
wall and streams the output back over a mutually-authenticated TLS channel.

Every release of this image is built `FROM` the **exact controller digest** published by the
same run, so `ansible-orchestrator:x.y.z` is provably the controller `x.y.z` with the
dispatcher layered on — never whatever `latest` pointed at on build day.

---

## Compare the images

| Image on Docker Hub | Purpose and where it runs |
|---|---|
| [ansible-controller](https://hub.docker.com/r/allamiro1/ansible-controller) | Standalone control host. Runs playbooks directly against reachable SSH or WinRM targets. |
| [ansible-orchestrator](https://hub.docker.com/r/allamiro1/ansible-orchestrator) | Mesh control host. Includes the controller runtime and dispatches signed jobs through Receptor ingress sidecars to execution nodes. |
| [ansible-execution-node](https://hub.docker.com/r/allamiro1/ansible-execution-node) | Inside each target network. Runs mesh jobs against local targets and connects outbound to the control host; no running SSH server. |

All three support `linux/amd64` and `linux/arm64`. Controller and mesh use the same release versions; choose the image for its role. GitLab integration is optional.

## Reviewed Git sync, execution approval and reports

GitLab is optional; native `make mesh-run` and `make mesh-collect` remain available.
The repository's separately installed `ctl-run` integration supports:

1. Review and merge the Git change, then sync the exact commit with `--sync-only`.
   Sync stages and validates the project without running a playbook or inventory plugin.
2. Review the receipt's commit, inventory and configured node/pool/zone. Manually
   approve execution with `--execute-synced`; staged bytes and the environment
   mapping are checked before dispatch, without another Git fetch.
3. Inspect HTML, JSON and JUnit reports: commit provenance, operation and transfer
   exit codes, controller state, and available final Ansible recap totals. Missing
   evidence or unresolved outcomes do not report success.

The administrator can require this flow with `require_sync: true`. Sync can also
have its own manual approval. In GitLab CE these are protected-ref, trusted-review
and manual-job controls, not an enforced independent reviewer count. A job Retry
reuses the recorded request; a new pipeline is a new request. Recover ambiguous
or incomplete work before releasing another execution.

**Upgrade the complete controller `gitlab/bin/` integration and the project's CI
scripts/templates. Pulling this image alone does not update an existing GitLab
installation.** See [setup](https://github.com/allamiro/ansible-controller/blob/main/gitlab/MAINTAINER-README.md)
and [sync, approvals, reporting, upgrades and 100+ system rollouts](https://github.com/allamiro/ansible-controller/blob/main/gitlab/MESH-ROLLOUTS.md).
Use canaries and Ansible `serial` batches; a mesh pool selects a node, rather than
partitioning inventory automatically across network zones.

## Voluntary support — continue free

Interactive Bash shells in mesh images show **Learn more**, **Sponsor**, and
**Continue free** links. The notice never waits for input, stays silent in CI and
command sessions, and does not enter worker protocol output. Set
`ANSIBLE_CONTROLLER_SUPPORT_NOTICE=0` or create `~/.hushlogin` to hide it;
`controller-support` displays it on demand in a terminal.

- [Contact Tamir Suliman for deployment assistance](mailto:tsuliman@linuxvaults.com?subject=Ansible%20Controller%20support%20enquiry) · [Support scope and terms](https://github.com/allamiro/ansible-controller/blob/main/SUPPORT.md)
- [GitHub Sponsors](https://github.com/sponsors/allamiro)
- [Buy Me a Coffee](https://buymeacoffee.com/pcileky2q)

Contributions and paid assistance are optional. Both controller and mesh remain
open source with **no host limit or purchase requirement**, including fleets
larger than 100 systems. The standalone controller has no automatic notice.

## Supported tags

Versions are cut automatically on every merge to `main`
(Conventional Commits: `feat:` bumps minor, `fix:` bumps patch). The orchestrator,
execution node, and controller always share the same version number.

| Tag | Meaning | Use it when |
|-----|---------|-------------|
| `x.y.z` (e.g. `0.29.0`) | Versioned release | **Production** — use a tested version; pin its digest for fixed content |
| `x.y`, `x` | Rolling within minor / major | You want patch/minor updates automatically |
| `latest` | Last successful build of `main` | Trying things out |
| `main` | Same as `latest` | — |
| `sha-<shortsha>` | Exact commit build | Audits, reproducible pipelines, rollback |

See the **Tags** tab for the current version list. Commands below use `0.29.0`
as a published example; choose your tested release and keep the three images aligned.

## Quick reference

- **Source / Dockerfile:** https://github.com/allamiro/ansible-controller
  (`docker/mesh/Dockerfile`, target `orchestrator`)
- **Mesh guide:** https://github.com/allamiro/ansible-controller/blob/main/mesh/README.md ·
  **Operator runbook:** https://github.com/allamiro/ansible-controller/blob/main/mesh/RUNBOOK.md
- **Issues & feature requests:** https://github.com/allamiro/ansible-controller/issues
- **Also published to GHCR:** `ghcr.io/allamiro/ansible-orchestrator`
- **Architectures:** `linux/amd64`, `linux/arm64` — both built on native runners
- **User:** `ansible` (uid 1000, passwordless sudo) · **Exposed port:** 22 (SSH) — identical
  to the controller
- **Maintainer:** Tamir Suliman

## What's inside

Everything in the controller — current `ansible-core`, `ansible.posix` and
`community.general`, OpenSSH server, the self-installing Galaxy / pip configuration —
completely unchanged, plus:

- **`mesh-run`** at `/usr/local/mesh/bin/mesh-run` — the dispatcher. Streams a playbook to a
  node, relays its events live, and exits with the playbook's **real** exit code.
- **`ansible-runner` 2.4.3** — packages the run (transmit) and reconstructs artifacts
  (process) on this side of the mesh.
- **`receptorctl` 1.6.7** — talks to the receptor ingress sidecars over their control sockets.

The build **asserts** at image-build time that no controller package pin moved and that the
added set is exactly the pinned closure above, so the orchestrator is reproducible for a given
controller digest. One deliberate, documented exception: `click` is pinned to 8.3.3
because `receptorctl` 1.6.7 caps it below 8.4.0. The controller's
only `click` consumer is `black` (via `ansible-lint`), which 8.3.3 satisfies, and `pip check`
re-verifies the whole dependency graph after the downgrade.

This image is the **control side only**. The mesh endpoints your nodes dial (ingress A and B)
are receptor sidecars started next to it by the repository's compose overlay; the mesh peer
that runs inside each closed network is the
[execution node](https://hub.docker.com/r/allamiro1/ansible-execution-node).

---

## Start it

### 1 — Issue identities (once, on an offline machine)

Every participant in the mesh presents a certificate you issued yourself, and every job
carries a signature from a key that lives only on the control host. The
[`mesh/pki/`](https://github.com/allamiro/ansible-controller/tree/main/mesh/pki) scripts do
the work; the [mesh guide](https://github.com/allamiro/ansible-controller/blob/main/mesh/README.md#step-1--issue-identities)
walks the sequence. The result is `mesh/secrets/receptor/issued/controller-a/` and
`controller-b/` (each `tls.crt` + `tls.key` + `ca.crt`) plus the work-signing keypair.

### 2 — Run the control plane from the repository

The repository ships the compose overlay with every mount wired up. Point the `ansible`
service at this image and start with the `mesh` profile:

```bash
git clone https://github.com/allamiro/ansible-controller.git
cd ansible-controller
# ... place the issued identities under mesh/secrets/ (step 1) ...

cat > orchestrator.override.yml <<'YML'
services:
  ansible:
    image: allamiro1/ansible-orchestrator:0.29.0
YML

docker compose -f docker-compose.yml -f mesh/compose.mesh.yml \
  -f orchestrator.override.yml --profile mesh up -d

make mesh-status                 # both ingress views; nodes appear under "Known Nodes"
make mesh-ping NODE=exec-dmz-a   # round-trip to one node
```

Ingress A listens on host port **27199** and ingress B on **27200** — the two ports your
execution nodes dial out to. Allow inbound TCP on those ports on the control host from the
node networks (host firewall, security group, or perimeter). Publishing them in compose does
not open anything upstream. Omit `--profile mesh` and nothing mesh-related is created; the
direct `make run` path is untouched either way.

### 3 — Dispatch a playbook

`PLAYBOOK` is relative to `playbooks/` and `INVENTORY` to `configs/`, the same conventions
as `make run`:

```bash
make mesh-run NODE=exec-dmz-a PLAYBOOK=site.yml INVENTORY=inventory/dmz.ini
make mesh-run ZONE=dmz PLAYBOOK=site.yml INVENTORY=inventory/dmz.ini WAIT=120
make mesh-collect JOB="<job-id>"   # recover a job reported results-incomplete
```

Or call the dispatcher directly inside the container for flags `make` doesn't surface:

```bash
docker exec -i ansible-controller /usr/local/mesh/bin/mesh-run \
  --zone dmz --playbook /configs/playbooks/site.yml --inventory /configs/inventory/dmz.ini \
  --ssh-key /home/ansible/.ssh/id_ed25519 --wait 120 \
  --ansible-cfg /configs/ansible.cfg --galaxy-dir /configs/.galaxy
```

The job runs **on the node**, so only what travels with it is available there: `make mesh-run`
ships the playbook directory and inventory. If your playbooks depend on the controller's
`ansible.cfg` or on roles and collections installed from `requirements.yml`, pass
`--ansible-cfg` and `--galaxy-dir` as above. Python packages a plugin needs at runtime
(`boto3` and friends) are not per-job content — bake them into the node image instead (see
the execution node's page).

| Flag | Purpose |
|------|---------|
| `--node <id>` / `--pool <name>` / `--zone <name>` | Where to run — exactly one. Pools and zones pick a healthy node with a free slot |
| `--playbook <file>` / `--inventory <file>` | Container paths under `/configs` |
| `--ssh-key <file>` | Private key for the node to reach its targets; travels only inside the encrypted stream, never logged, cleaned up at job exit; abrupt failures require operator cleanup |
| `--ansible-cfg <file>` | Ship an `ansible.cfg` with the job (e.g. `/configs/ansible.cfg`). The node runs the playbook with **its own** defaults otherwise. Refused if the playbook directory already ships one |
| `--galaxy-dir <dir>` | Ship Galaxy content with the job: the directory's `roles/` and `collections/` are merged next to the playbook (the controller installs to `/configs/.galaxy`). A same-name clash with the playbook's own roles is refused rather than silently shadowed |
| `--wait <seconds>` | Block until a slot frees instead of refusing pre-submit (default `0`, fail fast) |
| `--collect <job-id>` | Re-attach to a `results-incomplete` job: records the real result and frees its slot **without re-executing** |
| `--jobs-dir`, `--log-dir`, `--pools-file`, `--zones-file`, `--socket` | Override the defaults listed under Volumes |

What you get back: live events in your terminal, the playbook's real exit code in `$?`, a
per-job directory under `/var/lib/mesh/jobs/<uuid>/` (stdout, per-task events,
`meta.json` with timestamped status transitions), and the operator-facing artifacts copied
to `/var/log/ansible/runner/<uuid>/` — on the host as `logs/runner/<uuid>/`.

**No automatic resubmission after an attempted dispatch.** Candidate failover happens
only before submission. An unknown outcome requires recovery: use `--collect` when
a tracked unit exists; for an unknown unit, follow the runbook's ambiguous-submission
procedure. This is not a guarantee of exactly-once execution across new requests.

---

## Configuration reference

### Volumes

The controller's mounts (`/configs`, `/configs/playbooks`, `/home/ansible/.ssh`,
`/var/log/ansible`, `/etc/ssh/host_keys`) apply unchanged. The compose overlay adds:

| Container path | Mount | Purpose |
|----------------|-------|---------|
| `/run/receptor` | shared volume | Control sockets of ingress A (`receptor.sock`) and B (`receptor-b.sock`); the dispatcher tries A first and fails over to B |
| `/var/lib/mesh` | named volume | Dispatcher state: per-job data under `jobs/`, concurrency slot reservations and durable `.hold` markers under `slots/`. Must outlive the container |
| `/etc/mesh/pools.yml` | bind, ro | Pools: ordered candidate nodes with per-node `max_concurrent`. Read per dispatch — edit on the host, no restart |
| `/etc/mesh/zones.yml` | bind, ro | Zones: friendly names mapping to pools |

### Environment variables

| Variable | Purpose |
|----------|---------|
| `ANSIBLE_VAULT_PASSWORD` | As in the controller — Vault password, exported to sessions as `ANSIBLE_VAULT_PASSWORD_FILE` |
| `MESH_POOLS_FILE`, `MESH_ZONES_FILE` | Alternative locations for the pool / zone declarations |
| `MESH_SLOTS_DIR` | Alternative location for slot reservations (default `/var/lib/mesh/slots`) |

---

## Security posture

- **mTLS in both directions, no exceptions.** Ingresses accept only certificates issued by
  your own CA, whose key never joins the mesh. Nodes dial *out*, so the closed networks they
  sit in need no inbound holes. The control host must accept inbound TCP on **27199** and
  **27200** from those networks; compose publishing the listeners is not a firewall rule.
- **Only the control plane can hand out work.** Every submission is signed with a key that
  exists only on the control host; nodes refuse unsigned work before executing anything.
  Joining the mesh and submitting work are separate authorities.
- **Credential hygiene per job** — an SSH key passed with `--ssh-key` is never logged or
  placed in an environment variable, and cleanup runs at job exit. Abrupt host/process failure can retain data;
  follow the runbook for recovery and cleanup.
- **Inherits the controller's hardening** — key-only SSH, `PermitRootLogin no`, non-root
  `ansible` user, no secrets in the image, CVE-patched base — and the build fails if the
  dispatcher layer would move any controller dependency.
- **Every published image is Trivy-scanned** (fails on fixable CRITICAL/HIGH) and
  **cosign-signed** keylessly via GitHub OIDC. Verify before you run:

```bash
cosign verify \
  --certificate-identity-regexp 'https://github\.com/allamiro/ansible-controller/\.github/workflows/docker-publish\.yml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  docker.io/allamiro1/ansible-orchestrator:latest
```

## Try the disposable mesh test environment

Stand up the complete system on one machine — orchestrator, both ingresses, an execution
node, and a target the control plane genuinely cannot route to — and watch a playbook cross
the wall while the disposable regression suite exercises mesh behavior (including that missing,
expired, wrong-identity, and wrong-CA certificates are refused):

```bash
git clone https://github.com/allamiro/ansible-controller.git && cd ansible-controller
docker build -f docker/Dockerfile -t ansible-controller:dev .
mesh/tests/e2e-up.sh ansible-controller:dev
mesh/tests/e2e-check.sh
mesh/tests/e2e-down.sh
```

## License

[Apache License 2.0](https://github.com/allamiro/ansible-controller/blob/main/LICENSE) —
see the GitHub repository for source, CI definitions, and contribution guidelines.
