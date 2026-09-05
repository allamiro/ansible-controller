# Ansible Execution Node

The mesh peer that **runs playbooks inside networks your controller can't reach**. Place
one in each closed network — a DMZ, an OT segment, an isolated VLAN, a remote site. It dials
*out* to your control host over mutually-authenticated TLS, receives signed jobs from the
[orchestrator](https://hub.docker.com/r/allamiro1/ansible-orchestrator), runs them locally
over plain SSH against the targets it can see, and streams the output back. No inbound
firewall holes, no VPN, no agent on the targets.

It is the [Ansible Controller](https://hub.docker.com/r/allamiro1/ansible-controller)'s
full Ansible runtime plus [receptor](https://github.com/ansible/receptor) — and **no SSH
server**: nothing ever connects *into* a node.

---

## Supported tags

Versions are cut automatically on every merge to `main`
(Conventional Commits: `feat:` bumps minor, `fix:` bumps patch). The execution node,
orchestrator, and controller always share the same version number, and each release of
this image is built `FROM` the exact controller digest published by the same run.

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
  (`docker/mesh/Dockerfile`, target `execution-node`)
- **Mesh guide:** https://github.com/allamiro/ansible-controller/blob/main/mesh/README.md ·
  **Operator runbook (enroll, rotate, evict):**
  https://github.com/allamiro/ansible-controller/blob/main/mesh/RUNBOOK.md
- **Issues & feature requests:** https://github.com/allamiro/ansible-controller/issues
- **Also published to GHCR:** `ghcr.io/allamiro/ansible-execution-node`
- **Architectures:** `linux/amd64`, `linux/arm64` — both built on native runners
- **User:** uid 1000 (`ansible`), receptor runs as PID 1 · **Exposed ports:** none
- **Health check:** built in — `receptorctl status` on the node's local control socket, so
  `docker compose up --wait` returns only once the node is actually up
- **Maintainer:** Tamir Suliman

## What's inside

- The controller's complete Ansible runtime — current `ansible-core`, `ansible.posix`,
  `community.general`, `pywinrm` + NTLM, and the controller-side Python libraries their
  plugins need — so a playbook behaves on the node exactly as it does on the controller.
- **`receptor` 1.6.7** — the mesh agent, a static binary **rebuilt from the exact upstream
  release commit** with its Go module dependencies (`x/crypto`, `x/net`, `x/text`) bumped to
  CVE-fixed versions, because the upstream binary fails this project's scanner gate.
- **`ansible-runner` 2.4.3** — the worker that executes each streamed job.
- **`receptorctl`** — for the health check and on-node debugging.
- Entrypoint that renders receptor's config from the environment on every start and refuses
  to start without a certificate bundle and a work-signing public key.

---

## Start it

### 0 — Before it can join

A node needs two things from your control plane's PKI (the
[mesh guide](https://github.com/allamiro/ansible-controller/blob/main/mesh/README.md#step-1--issue-identities)
walks the request → sign → install sequence):

- **Its certificate bundle** — `tls.crt` + `tls.key` + `ca.crt`, issued by your offline CA
  for this node's exact name. The private key is generated on the node host and never
  leaves it.
- **The work-signing public key** — `work-public.pem`, the *public* half only. The private
  half stays on the control host.

Node names become the addresses you dispatch to, so name nodes after their network:
`exec-dmz-a`, `exec-ot-b`, and so on.

### Option 1 — docker compose (recommended)

Copy [`mesh/compose.node.yml`](https://github.com/allamiro/ansible-controller/blob/main/mesh/compose.node.yml)
and [`mesh/node.env.example`](https://github.com/allamiro/ansible-controller/blob/main/mesh/node.env.example)
to the node host — no checkout needed — and put the bundle beside them:

```text
.
├── compose.node.yml
├── .env                                   # copied from node.env.example
└── secrets/receptor/
    ├── issued/exec-dmz-a/{tls.crt,tls.key,ca.crt}
    └── work-signing/work-public.pem
```

```bash
# .env
RECEPTOR_NODE_ID=exec-dmz-a
RECEPTOR_PEERS=ctrl.example.com:27199,ctrl.example.com:27200
MESH_NODE_IMAGE=allamiro1/ansible-execution-node:0.23.1
```

```bash
chown -R 1000:1000 secrets/receptor/issued/exec-dmz-a   # the container reads the bundle as uid 1000
docker compose -f compose.node.yml up -d --wait          # returns once the node is HEALTHY
```

The node restarts with its host (`restart: unless-stopped`) and appears in
`make mesh-status` on the control host.

### Option 2 — plain docker run

```bash
docker run -d --name mesh-node-exec-dmz-a --restart unless-stopped \
  --tmpfs /run/receptor:uid=1000,gid=1000,mode=0750 \
  -v "$PWD/secrets/receptor/issued/exec-dmz-a":/etc/receptor/tls:ro \
  -v "$PWD/secrets/receptor/work-signing/work-public.pem":/etc/receptor/signing/work-public.pem:ro \
  -e RECEPTOR_NODE_ID=exec-dmz-a \
  -e RECEPTOR_PEERS=ctrl.example.com:27199,ctrl.example.com:27200 \
  -e RECEPTOR_TLS_CERT=/etc/receptor/tls/tls.crt \
  -e RECEPTOR_TLS_KEY=/etc/receptor/tls/tls.key \
  -e RECEPTOR_TLS_CA=/etc/receptor/tls/ca.crt \
  -e RECEPTOR_WORK_PUBKEY=/etc/receptor/signing/work-public.pem \
  allamiro1/ansible-execution-node:0.23.1
```

No `-p` flags: the node publishes nothing. It only needs outbound TCP to the control host
on **27199** (ingress A) and **27200** (ingress B), and SSH reachability to its targets.

### Then, on the control host

Add the node to `mesh/config/pools.yml` (and a zone in `zones.yml`) and dispatch:

```bash
make mesh-ping NODE=exec-dmz-a
make mesh-run NODE=exec-dmz-a PLAYBOOK=site.yml INVENTORY=inventory/dmz.ini
```

---

## Configuration reference

### Environment variables

| Variable | Required | Purpose |
|----------|----------|---------|
| `RECEPTOR_NODE_ID` | yes | This node's identity — must match the name in its certificate; the ingress rejects a mismatch. Treat as permanent |
| `RECEPTOR_PEERS` | yes | Comma-separated `host:port` list of ingresses to dial. Give both (A and B) so one can fail |
| `RECEPTOR_TLS_CERT`, `RECEPTOR_TLS_KEY`, `RECEPTOR_TLS_CA` | yes | Paths to the node's certificate, private key, and the mesh CA certificate |
| `RECEPTOR_WORK_PUBKEY` | yes | Path to the work-signing **public** key; every incoming job's signature is verified against it |
| `RECEPTOR_LOG_LEVEL` | no | `debug` \| `info` \| `warning` \| `error` (default `info`) |
| `RECEPTOR_INSECURE_DEV` | never in production | `1` runs with **no TLS and no signature check** — exists solely for throwaway wiring experiments and warns loudly at startup |

All values are validated against a strict character set before being rendered into
receptor's configuration, so an environment value cannot inject extra receptor actions.

### Mounts

| Container path | Mount | Purpose |
|----------------|-------|---------|
| `/etc/receptor/tls` | bind, ro | The issued bundle (`tls.crt`, `tls.key`, `ca.crt`) |
| `/etc/receptor/signing/work-public.pem` | bind, ro | The work-signing public key |
| `/run/receptor` | tmpfs (`uid=1000,gid=1000,mode=0750`) | Rendered config and the owner-only control socket — never the writable layer |

### Adding Python dependencies for your playbooks

Plugins that need Python packages on the machine running Ansible — cloud inventory SDKs
like `boto3` are the classic case — need them **on the node**, since that is where the
playbook runs. Extend the image once, exactly as the controller does:

```dockerfile
FROM allamiro1/ansible-execution-node:0.23.1
USER root
COPY node-requirements.txt /tmp/node-requirements.txt
RUN pip3 install --no-cache-dir --break-system-packages -r /tmp/node-requirements.txt \
 && rm /tmp/node-requirements.txt
USER ansible
```

Pin the versions in `node-requirements.txt`, build it as your site tag, and set
`MESH_NODE_IMAGE` to it.

---

## Health and troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| Node missing from `make mesh-status` | It can't reach ports 27199/27200 on the control host, or its TLS bundle is wrong | Test outbound reachability from the node host; check `docker logs` — a refused TLS handshake means a certificate problem |
| Connection refused by the ingress | Expired certificate, wrong identity in the certificate, or a bundle from a different CA | Re-issue (new request on the node, sign offline, install, restart). This is deliberate — an unauthenticated node must never join |
| Container exits immediately | A required variable or file is missing, or a value failed validation | The entrypoint says exactly which one on stderr |
| Playbook failed | The playbook itself failed — the mesh reports honestly | Read the job's artifacts on the control host: `logs/runner/<uuid>/` |

---

## Security posture

- **No certificate, no entry.** Mutual TLS is mandatory; the node presents its own
  certificate and verifies the ingress presents one signed by your CA for *its* identity.
  There is no plaintext fallback (short of the loud `RECEPTOR_INSECURE_DEV` escape hatch).
- **Nodes dial out only.** No listener for the mesh, no SSH server, no published ports.
  Your inbound firewall rules stay exactly as they are.
- **Signed work only.** Every job is verified against the control plane's signing key
  before execution, so even a compromised or partner-operated node can *run* jobs but
  never *inject* them.
- **Unprivileged.** receptor runs as PID 1 under uid 1000; the control socket is owner-only
  and lives on tmpfs.
- **Per-job credential hygiene** — an SSH key that arrives with a job is destroyed by the
  worker the moment execution finishes, even if the control plane never reconnects.
- **Every published image is Trivy-scanned** (fails on fixable CRITICAL/HIGH — which is why
  receptor is rebuilt from source with patched dependencies) and **cosign-signed** keylessly
  via GitHub OIDC. Verify before you run:

```bash
cosign verify \
  --certificate-identity-regexp 'https://github\.com/allamiro/ansible-controller/\.github/workflows/docker-publish\.yml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  docker.io/allamiro1/ansible-execution-node:latest
```

## License

[Apache License 2.0](https://github.com/allamiro/ansible-controller/blob/main/LICENSE) —
see the GitHub repository for source, CI definitions, and contribution guidelines.
