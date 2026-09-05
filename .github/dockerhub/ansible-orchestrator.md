# Ansible Orchestrator

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

## Supported tags

Versions are cut automatically on every merge to `main`
(Conventional Commits: `feat:` bumps minor, `fix:` bumps patch). The orchestrator,
execution node, and controller always share the same version number.

| Tag | Meaning | Use it when |
|-----|---------|-------------|
| `x.y.z` (e.g. `0.23.1`) | Immutable release | **Production** — pin the full version |
| `x.y`, `x` | Rolling within minor / major | You want patch/minor updates automatically |
| `latest` | Last successful build of `main` | Trying things out |
| `main` | Same as `latest` | — |
| `sha-<shortsha>` | Exact commit build | Audits, reproducible pipelines, rollback |

See the **Tags** tab for the current version list.

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

The build **asserts** at image-build time that not one controller package pin moved and that
the added set is exactly the pinned closure above, so the orchestrator is reproducible for a
given controller digest.

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
    image: allamiro1/ansible-orchestrator:0.23.1
YML

docker compose -f docker-compose.yml -f mesh/compose.mesh.yml \
  -f orchestrator.override.yml --profile mesh up -d

make mesh-status                 # both ingress views; nodes appear under "Known Nodes"
make mesh-ping NODE=exec-dmz-a   # round-trip to one node
```

Ingress A listens on host port **27199** and ingress B on **27200** — the two ports your
execution nodes dial out to. Omit `--profile mesh` and nothing mesh-related is created; the
direct `make run` path is untouched either way.

### 3 — Dispatch a playbook

`PLAYBOOK` is relative to `playbooks/` and `INVENTORY` to `configs/`, the same conventions
as `make run`:

```bash
make mesh-run NODE=exec-dmz-a PLAYBOOK=site.yml INVENTORY=inventory/dmz.ini
make mesh-run ZONE=dmz PLAYBOOK=site.yml INVENTORY=inventory/dmz.ini WAIT=120
make mesh-collect JOB=<job-id>   # recover a job reported results-incomplete
```

Or call the dispatcher directly inside the container for flags `make` doesn't surface:

```bash
docker exec -i ansible-controller /usr/local/mesh/bin/mesh-run \
  --zone dmz --playbook /configs/playbooks/site.yml --inventory /configs/inventory/dmz.ini \
  --ssh-key /home/ansible/.ssh/id_ed25519 --wait 120
```

| Flag | Purpose |
|------|---------|
| `--node <id>` / `--pool <name>` / `--zone <name>` | Where to run — exactly one. Pools and zones pick a healthy node with a free slot |
| `--playbook <file>` / `--inventory <file>` | Container paths under `/configs` |
| `--ssh-key <file>` | Private key for the node to reach its targets; travels only inside the encrypted stream, never logged, destroyed on both sides when the job ends |
| `--wait <seconds>` | Block until a slot frees instead of refusing pre-submit (default `0`, fail fast) |
| `--collect <job-id>` | Re-attach to a `results-incomplete` job: records the real result and frees its slot **without re-executing** |
| `--jobs-dir`, `--log-dir`, `--pools-file`, `--zones-file`, `--socket` | Override the defaults listed under Volumes |

What you get back: live events in your terminal, the playbook's real exit code in `$?`, a
per-job directory under `/var/lib/mesh/jobs/<uuid>/` (stdout, per-task events,
`meta.json` with timestamped status transitions), and the operator-facing artifacts copied
to `/var/log/ansible/runner/<uuid>/` — on the host as `logs/runner/<uuid>/`.

**A job never runs twice.** Failover between candidate nodes happens only *before*
submission. Once a node has (or even may have) accepted a job, it is never re-sent; an
ambiguous outcome is reported as such for you to `--collect`.

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
  your own CA, whose key never joins the mesh. Nodes dial *out*; no inbound firewall change
  is needed anywhere.
- **Only the control plane can hand out work.** Every submission is signed with a key that
  exists only on the control host; nodes refuse unsigned work before executing anything.
  Joining the mesh and submitting work are separate authorities.
- **Credential hygiene per job** — an SSH key passed with `--ssh-key` is never logged or
  placed in an environment variable, and every transient copy is removed when the job ends.
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

## Try the whole mesh in ten minutes

Stand up the complete system on one machine — orchestrator, both ingresses, an execution
node, and a target the control plane genuinely cannot route to — and watch a playbook cross
the wall while a 29-check suite proves every guarantee above (including that missing,
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
