# Distributed Execution Mesh — Design & Implementation Plan

> Looking for the operator overview — architecture diagrams, quick start,
> images, testing? That is [`README.md`](README.md). This file is the design
> of record.

> **Status: approved; landing one phase per PR.** This document describes how
> distributed Ansible execution and control-plane HA are added to this repository
> *without changing the existing controller image or its behaviour*. It remains
> the design of record — the checklist in [§7](#7-to-do-checklist) tracks what has
> actually shipped, and the phases still unticked are plan, not code.

---

## 0. Purpose

Add a second execution path to the existing Ansible controller:

- **Direct (existing):** `make run` — the controller executes Ansible itself. Unchanged.
- **Distributed (new):** work is dispatched to **execution nodes** grouped into
  **pools per zone**. The controller becomes an *orchestrator*; execution happens
  on the nodes, not on the controller.

The mesh differentiates **local** targets (a directly-reachable zone) from
**network** targets (segmented zones reachable only through a node), and provides
HA at two independent layers: **execution-node pools** and the **control plane**.

Built on **Receptor + Ansible Runner + mTLS** only. No web UI, REST API, database,
message broker, or scheduler service — see [§11 Non-goals](#11-explicitly-deferred--non-goals).

**Documentation map** (which page owns what — update the owner when behavior
changes): [README.md](README.md) is the entry point and first-deployment
guide; [RUNBOOK.md](RUNBOOK.md) owns day-2 procedures (enrollment, rotation,
eviction, upgrade, recovery); this document owns the *why* — architecture,
trust boundaries, failure semantics, tradeoffs — and the test matrix that
keeps the other two honest.

---

## 1. Non-disruption guarantees (how the existing controller is protected)

These are load-bearing. The existing controller must be provably unchanged until
an operator opts in.

| # | Guarantee | Enforced by |
|---|-----------|-------------|
| 1 | Root `docker-compose.yml`, `Makefile` direct targets, and the **controller image** stay identical | `docker/Dockerfile` is **untouched**; mesh images build from a separate `docker/mesh/Dockerfile` `FROM` the controller and never modify it; controller proven byte/scan-identical (see [§9.1](#91-non-disruption-checks-run-every-mesh-pr)) |
| 2 | `make up` / `make down` / `make run` behave exactly as today | Sidecar and nodes are **Compose-profile-gated** (`--profile mesh`); default `up` never starts them |
| 3 | The controller build context is unchanged | `mesh/` is excluded via `.dockerignore` |
| 4 | The release pipeline (#54–#57: cosign, semver, Trivy gate) is untouched | Node/relay images are **not** added to `docker-publish.yml` until a deliberate later phase |
| 5 | The CVE posture stays clean | Mesh images build `FROM` the controller, inheriting its pip-vendor patch + pebble removal automatically; every mesh image is scanned by the same gate before it can publish |

**Rule:** any mesh PR whose CI shows a change to the controller image scan (still 0
CRITICAL/HIGH) or a failing controller smoke test is rejected, not merged.

---

## 2. Architecture

### 2.1 Direct vs distributed

```text
DIRECT (existing, unchanged)
   Controller ───SSH──► Target

DISTRIBUTED (new)
   Controller (orchestrator)
       │ ansible-runner transmit
       ▼
   Controller Receptor (sidecar)
       │ Receptor mTLS
       ▼
   Execution node (receptor + ansible-runner + ansible-core)
       │ SSH / WinRM
       ▼
   Target
       │ job events / rc
       ▼  (back up the same path)
   Controller  ──►  CLI output + artifacts
```

### 2.2 Two independent HA layers

HA is provided at two layers that fail and recover independently:

- **Execution-node HA** — multiple nodes per zone; dispatch fails over between them.
- **Control-plane HA** — see [§3](#3-ha-decisions-agreed). Tier 1 (ingress
  redundancy) is native to Receptor; Tier 2 (active/active orchestrators) is
  designed-for but built later.

### 2.3 HA topology (target design)

```text
                         Operators / CLI
                               │
                     VIP  or  DNS round-robin
                        ┌──────┴──────┐
                        ▼             ▼
                ┌──────────────┐ ┌──────────────┐
                │ CONTROL-A    │ │ CONTROL-B    │   active/active, on-demand
                │ orchestrator │ │ orchestrator │   (no scheduler → no leader
                │ + receptor   │ │ + receptor   │    election needed)
                └──────┬───────┘ └───────┬──────┘
                       │   shared state  │   playbooks (git), PKI pub,
                       └────────┬────────┘   zones/pools, per-job meta.json
                                │
                    ┌───────────┴───────────┐
                    │   RECEPTOR MESH        │  both A & B are ingress peers;
                    │  (routes around a      │  nodes: tcp-peers=[A,B] redial
                    │   dead ingress)        │
                    └───────────┬───────────┘
              ┌─────────────────┼─────────────────┐
              ▼                 ▼                 ▼
         pool: local       pool: net20        pool: net30
        (N exec nodes)   (N exec nodes, HA)  (N exec nodes)
              │                 │  ▲               │
           SSH/WinRM         SSH/WinRM │        SSH/WinRM
              ▼                 ▼   failover        ▼
          local targets     net20 targets      net30 targets

   CA private key: OFFLINE only — never on A or B. Not a runtime SPOF.
```

### 2.4 Dispatch & failover flow (per job)

```text
 mesh-run ZONE=net20 PLAYBOOK=patch.yml LIMIT=web01
     │
     ├─(1) classify: ZONE=net20 → pool = [exec-net20-a, exec-net20-b]
     ├─(2) receptorctl status → healthy = reachable subset of the pool
     ├─(3) select (round-robin) → exec-net20-a
     ├─(4) build UNIQUE private_data_dir  jobs/<uuid>/
     ├─(5) write per-job jobs/<uuid>/meta.json {job-id, node, unit-id, status}
     │        (one file per job — no shared-file race between concurrent runs)
     ├─(6) ansible-runner transmit → receptorctl work submit --node exec-net20-a
     │        │
     │        ├─ submit ACKed — OR any lost/ambiguous response ──► ⛔ NON-RETRYABLE
     │        │       the unit may be running; on failure → REPORT, never retry
     │        │       elsewhere. A lost ACK is not proof that nothing ran.
     │        │
     │        └─ DEFINITIVELY pre-submit only (node absent from receptorctl
     │                 status, or connection refused before the request was sent)
     │                 └─ failover → exec-net20-b   ✅ safe (submit never left)
     ├─(7) stream events → ansible-runner process ; update meta.json status
     ├─(8) artifacts → logs/runner/<job-id>/  (stdout, rc, job_events)
     └─(9) return Ansible rc
```

**The failover boundary is the most important correctness rule in this design.**
Failover is allowed **only for submissions that definitively never left the
controller** — the target node is absent from `receptorctl status`, or the
connection was refused before the request was sent. A submission that was ACKed —
*or whose response was lost or ambiguous* — is treated as possibly-running and is
**never** retried elsewhere; a lost ACK is not proof that nothing ran. Each job
carries a stable work-unit id, so its real state can be queried (`receptorctl work
list`/`status`) instead of inferred from a failed call.

---

## 3. HA decisions (agreed)

| Tier | What | Decision |
|------|------|----------|
| **1** | **≥2 Receptor ingress sidecars** on the control host (orchestrator fails its control socket over between them) **+** execution nodes multi-peer with redial | **Build now.** Native, cheap, real. Survives losing one sidecar/ingress; losing the orchestrator *host* is Tier 2. |
| **2** | Active/active orchestrators (VIP/DNS, shared config+PKI, git playbooks) | **Design for it, build when a real 2-host target exists.** Interim recovery = documented fast orchestrator restart (state is external, so seconds). |
| **2.5** | Recover an in-flight job’s live stream onto the surviving orchestrator | **Don’t build the recovery logic.** But write a per-job `meta.json` now (for status/history) so the logic is nearly free later. Meaningless until Tier 2 exists. |
| **3** | Full stateful HA (real state store) | **Don’t.** That store is a database; if ever truly required, evaluate adopting **AWX** instead of reimplementing it. |

**In-flight failure posture (interim):** if an orchestrator dies mid-job, the job
keeps running on the execution node (Receptor is store-and-forward); the live
stream is lost; recovery is re-query artifacts or re-run (playbooks are idempotent).

---

## 4. Day-one invariants (make HA cheap later, cost ~0 now)

Hold these from the first mesh commit even in the single-orchestrator build:

| Invariant | Why | Cost now |
|-----------|-----|----------|
| Orchestrator holds **no local-only state** — all state on mountable/shared storage or git | One→two orchestrators becomes config, not a rewrite | discipline only |
| Every job gets a **stable UUID** and a **per-job `jobs/<uuid>/meta.json`** (one file per job — concurrency-safe by construction) | Status/history today; Tier 2.5 recovery later | small; wanted anyway |
| Execution nodes peer to a **list** of ingress addresses (even a list of one) | Tier 1 becomes "add controller-B to the list" | ~0 |
| CA private key **never** on a runtime container | CA is not a runtime SPOF; signing is offline | ~0 |

**PKI material is never committed to git.** The CA, certs, keys, and CSRs all live
under `mesh/secrets/` on shared storage and are distributed by the signing workflow
([§6 Phase 6](#6-phased-implementation-plan)); public certs are shared the same way,
not tracked in the repo. "Shared config+PKI" above means shared *storage*, not the
repository.

---

## 5. Directory layout

Everything mesh-specific lives under `mesh/`. **The existing `docker/Dockerfile`
is left unchanged** — it stays the single-stage controller build, so a build with
no `--target` still produces today's controller. The mesh images build from a
*separate* `docker/mesh/Dockerfile` that starts `FROM` the finished controller, so
they inherit its exact runtime (and its CVE remediation) with zero dependency drift
and zero change to the controller:

```text
docker/Dockerfile        →  controller        # UNCHANGED; the PUBLISHED image and
                                              #   the default (no-target) build

docker/mesh/Dockerfile:
  ARG BASE=<controller image>
  FROM ${BASE} AS orchestrator      # controller + ansible-runner + receptorctl
  FROM orchestrator AS execution-node # + receptor (patched source build);
                                    #   entrypoint runs receptor, NOT sshd; the
                                    #   inherited port-22 HEALTHCHECK is overridden
                                    #   with a receptor-readiness check (inherited
                                    #   sshd is never started — a later slimming target)
```

Why not a shared `ansible-runtime` base stage inside `docker/Dockerfile`? Two
review findings ruled it out: (a) declaring `execution-node` as a later stage makes
it the *default* build target, so the existing pipeline — which sets no `target:` —
would publish a mesh image under the controller name; and (b) putting orchestration
packages in a shared base leaks them into the published controller, breaking the
byte-identical guarantee. Building the mesh images `FROM` the finished controller
sidesteps both: the controller build is untouched, and the mesh images are explicit,
never-default `--target` builds. Their build inputs (entrypoints) live under
`docker/mesh/` — inside the build context — so the top-level `mesh/` tree stays
`.dockerignore`d and contributes nothing to any image.

```text
ansible-controller/
├── docker/
│   ├── Dockerfile              # UNCHANGED single-stage controller (default build)
│   └── mesh/                   # mesh image builds — FROM the controller image
│       ├── Dockerfile          #   targets: orchestrator, execution-node
│       ├── orchestrator-entrypoint.sh
│       └── node-entrypoint.sh  # renders receptor node config from env
├── docker-compose.yml          # UNCHANGED — controller only
├── Makefile                    # existing targets untouched; mesh targets appended
│
└── mesh/                       # ← the whole subsystem, isolated
    ├── README.md               # operator overview (diagrams, quick start)
    ├── DESIGN.md               # this document
    ├── compose.mesh.yml        # overlay: sidecar + local exec-node, profile-gated
    ├── compose.node.yml        # node-side deployment file: one node, env-driven
    ├── node.env.example        # its settings (node id, ingress addresses, image)
    ├── config/
    │   ├── zones.yml            # inventory group / network → zone (local | net20…)
    │   ├── pools.yml            # zone → [node_id, node_id]  (HA membership)
    │   └── receptor/
    │       ├── controller.yml
    │       └── node.yml.template
    ├── pki/                     # mesh-ca-init, controller-cert, node-csr, node-sign
    ├── bin/
    │   ├── mesh-run          # dispatcher (classify → select → submit → collect)
    │   ├── mesh-status.sh
    │   └── mesh-ping.sh
    ├── deploy/                  # HA overlays: multi-ingress, VIP, shared-storage mounts
    ├── secrets/                 # gitignored (keys never committed)
    │   └── receptor/.gitkeep
    └── tests/                   # multi-network lab + mTLS/SSH negative tests
```

---

## 6. Phased implementation plan

One PR per phase. Each is independently reversible. "Touches controller?" is the
risk column; anything that touches it must pass [§9.1](#91-non-disruption-checks-run-every-mesh-pr).

| Ph | Goal | Touches controller image? | Guardrail before merge |
|----|------|---------------------------|------------------------|
| 0 | SSH hardening: add managed `known_hosts` / strict path, label dev override; **do not flip default** | Config only, opt-in | Existing direct run still works with current default |
| 1 | Add `docker/mesh/Dockerfile` scaffold (`FROM` controller); **`docker/Dockerfile` untouched** | No — controller build unchanged | Controller smoke + Trivy = 0 unchanged, both arches ([§9.1](#91-non-disruption-checks-run-every-mesh-pr)) |
| 2 | `orchestrator` target in `docker/mesh/Dockerfile` (`FROM` controller + `ansible-runner` + `receptorctl`) | No — separate image, explicit `--target` | Controller digest unchanged; `orchestrator` scan 0 |
| 3 | `receptor-controller` sidecar + shared socket volume, **profile-gated** | No (opt-in) | `make up` unchanged |
| 4 | `execution-node` target in `docker/mesh/Dockerfile` (`FROM` controller + `receptor` + `ansible-runner`; entrypoint runs receptor; HEALTHCHECK → receptor readiness) + test lab, **no TLS (dev only)** | No | Local build only; never published |
| 5 | Prove `transmit → work submit → worker → process` across the mesh | No | Positive tests [§9.2](#92-positive-distributed-execution-tests) |
| 6 | PKI scripts + **mandatory mTLS** + **Tier-1** (2nd receptor sidecar, orchestrator control-socket failover, node multi-peer) | No | Negative mTLS + Tier-1 tests [§9.3](#93-negative-mtls-tests)/[§9.7](#97-control-plane-tier-1-ingress-redundancy) |
| 7 | Target SSH credential handling + artifacts + per-job `meta.json` | No | SSH-negative test [§9.4](#94-target-ssh-negative-test) |
| 8 | Pools + failover dispatcher (execution-node HA) + concurrency caps | No | HA + concurrency tests [§9.5](#95-execution-node-ha-failover)/[§9.6](#96-concurrency--parallelism) |
| 9 | Work signing (`--signwork`) — authorises the future third-party boundary | No | Signed-work test; unsigned rejected |
| 10 | Makefile convenience targets + docs/runbook | Appends only | Existing targets still work |
| 11 | *(optional, later)* publish + cosign + scan node image | Release pipeline | Extend the matrix, don’t fork it |
| — | **Deferred:** Tier 2 active/active; fan-out sharding; auto-routing engine | — | Built only when a real driver exists |

---

## 7. To-do checklist

### Phase 0 — SSH hardening (independent, can ship first)
- [x] Add a managed `known_hosts` mechanism + `StrictHostKeyChecking=yes` path
      (configs/ansible.cfg documents `/configs/known_hosts` + strict/accept-new)
- [x] Clearly label the existing lax settings as **dev-only** override
- [x] Document; do **not** change the current default (flip only at a major bump)

### Phase 1 — mesh build scaffold (controller Dockerfile untouched)
- [x] Add `docker/mesh/Dockerfile` with `ARG BASE`; `orchestrator` builds
      `FROM ${BASE}` and `execution-node` deliberately builds
      `FROM orchestrator` (the Phase 4 deviation recorded below)
- [x] Leave `docker/Dockerfile` unchanged; confirm the default (no-target) build is still the controller
- [x] Prove controller image smoke + Trivy = 0 on amd64 **and** arm64 (unchanged)

### Phase 2 — orchestrator image (separate, FROM controller)
- [x] `orchestrator` target = `FROM ${BASE}` + `pip install ansible-runner receptorctl`
- [x] Build only via explicit `--target orchestrator`; the published controller is never rebuilt
- [x] `orchestrator` scan 0; controller digest unchanged

### Phase 3 — controller receptor sidecar
- [x] `mesh/config/receptor/controller.yml` (Unix control socket, no TCP control)
      — receptor 1.6.7 takes a YAML **list** of action maps; it rejects the
      mapping/`version: 2` style with `cannot unmarshal !!map into []interface {}`
- [x] `mesh/compose.mesh.yml` with `receptor-controller` under `profiles: [mesh]`
- [x] Shared named volume `receptor-runtime:/run/receptor`
- [x] Verify `make up` still starts controller **only**
- [x] Sidecar drops to the unprivileged `receptor` uid; control socket is 0600

### Phase 4 — execution node + e2e integration environment
- [x] `execution-node` target + `receptor` + `ansible-runner` (Phase 5 submits `ansible-runner worker` here)
      — built `FROM` the orchestrator stage rather than `${BASE}` so the pinned
      pip closure and its build-time assertions exist in exactly one place
- [x] receptor rebuilt from the v1.6.7 tag commit with patched Go modules
      (x/crypto 0.55.0, x/net 0.57.0, x/text 0.41.0) — upstream's binary carries
      11 fixable HIGH CVEs and no fixed release exists yet; drop the source
      stage when upstream ships one
- [x] Override the inherited port-22 `HEALTHCHECK` with a Receptor-readiness check (node runs receptor, not sshd; runs as uid 1000)
- [x] `docker/mesh/node-entrypoint.sh` (render node config from env; peers is a LIST — Tier 1 ready)
- [x] `mesh/tests/` multi-network **e2e integration environment** (controller cannot reach targets) — regression suite (`e2e-check.sh`; 20 properties as of Phase 6), run by Mesh CI on every mesh change
- [x] **No-TLS** peering confined to the e2e environment (never in a production compose file)

### Phase 5 — prove distributed execution
- [x] `mesh/bin/mesh-run` (minimal: transmit → submit → worker → process) —
      per-job UUID + `jobs/<uuid>/meta.json` lifecycle from the first commit
      (day-one invariants, §4); success requires the artifacts' own `rc` file,
      because a broken results stream leaves `ansible-runner process` exiting 0
- [x] Node-side `mesh-worker` wrapper keeps the results stream protocol-pure —
      receptor merges the work command's stderr into the unit stdout, and one
      non-JSON line (OpenSSL greets stderr at every python start) makes the
      controller-side Processor abort at its first read
- [x] Positive test: controller can’t SSH target directly; `mesh-run` succeeds (e2e check 9)
- [x] "Prove-on-node" playbook shows node id, not controller (e2e check 10, both directions)
- [x] Real ansible rc + artifacts (stdout, rc, job_events) return to the controller (checks 11–13, including nonzero rc propagation)

### Phase 6 — PKI + mandatory mTLS
- [x] `mesh/pki/`: `mesh-ca-init.sh`, `controller-cert.sh`, `node-csr.sh`, `node-sign.sh`
      — receptor's own cert tooling (nodeid OID in SAN) run in the pinned image;
      signing is gated on the CSR carrying EXACTLY the authorised node id
- [x] Idempotent CA init (STOP if CA exists unless `--force`); CA key never in
      any runtime mount — only `issued/` bundles reach containers
- [x] Node-id ⇄ cert identity checking on; `insecureskipverify` /
      `skipreceptornamescheck` never set (e2e asserts their absence as active keys)
- [x] Multi-ingress peer list (Tier 1): nodes peer to A **and** B; the
      dispatcher fails its control socket over between the two sidecars
- [x] All negative mTLS tests pass — the full §9.3 matrix (e2e 15–19):
      certless node, unknown client CA, valid-cert-wrong-identity, EXPIRED
      cert, and (reversed) a node refusing a controller whose cert comes from
      an unknown CA + Tier-1 failover proven (e2e 20: sidecar A stopped,
      dispatch through B succeeds, A re-peers)
- [x] mTLS is MANDATORY: the node entrypoint refuses to start without cert,
      key, and CA. `RECEPTOR_INSECURE_DEV=1` is a loud, dev-only escape: no
      production file sets it, and the e2e suite uses it in exactly one place —
      as the ATTACKER in negative check 15, proving a plaintext node is
      rejected by the mesh

### Phase 7 — credentials, artifacts, job index
- [x] `env/ssh_key` in the transmit payload; never logged/echoed
- [x] Node runtime Python deps (pip-requirements.txt equivalents, e.g. boto3
      for cloud inventory plugins): document the site-image extension pattern
      (`FROM execution-node` + `pip install -r`) — per-job staging of compiled
      packages is the wrong layer (README "Node runtime Python dependencies")
- [x] Artifacts to `logs/runner/<job-id>/` (stdout, rc, job_events) — e2e #22
- [x] Write a per-job `jobs/<uuid>/meta.json` (one file per job — concurrency-safe,
      RFC 3339 `updated` on every transition)
- [x] Secure cleanup of transient key copies — controller copy shredded via
      EXIT trap (e2e #21); node copy dies with the released work unit

### Phase 8 — pools, failover, concurrency
- [x] `mesh/config/zones.yml` + `pools.yml` (templates; mounted at `/etc/mesh/`)
- [x] Dispatcher: classify → healthy-node select → submit → **dispatch-only failover** — e2e #23
- [x] Per-node concurrency cap via an atomic `flock` reservation on a per-node slot file (not a `work list` check) — e2e #24
- [x] Unique PDD + artifact dir + work-unit id per concurrent job (held since Phase 5; re-proven under contention by #24)

### Phase 9 — work signing
- [x] Controller work-signing private key (offline-issued via
      `mesh/pki/work-sign-init.sh`); nodes get only the verification pubkey
      (`RECEPTOR_WORK_PUBKEY`)
- [x] `verifysignature: true` on the node worktype (mandatory outside
      `RECEPTOR_INSECURE_DEV`); `mesh-run` submits `--signwork` by default
- [x] Test: unsigned work rejected — e2e #25

### Phase 10 — Make targets + docs
- [x] `mesh-up`, `mesh-down`, `mesh-status`, `mesh-ping`, `mesh-run` — the
      dispatcher is baked into the orchestrator image; pools/zones configs
      mount live-editable at `/etc/mesh/`
- [x] Runbook: create/enroll/sign/install/verify/run/rotate/revoke/troubleshoot
      — [`mesh/RUNBOOK.md`](RUNBOOK.md)
- [x] Confirm every pre-existing Make target still works (unchanged; verified
      by `make -n` across the full target list)
- [x] `mesh/compose.node.yml` + `node.env.example` — the packaged node-side
      deployment (the RUNBOOK's `docker run` as a file); e2e #26 starts a node
      from it, unmodified, and dispatches work to it

---

## 8. Use cases

| UC | Scenario | Expected outcome |
|----|----------|------------------|
| UC1 | **Local scan** via colocated local execution node | Runs on `exec-local-*`, not on the controller |
| UC2 | **Network scan** into segmented `net20` | Runs on `exec-net20-*`; controller has no route to the target |
| UC3 | **Execution-node failover** — `exec-net20-a` down at dispatch | `exec-net20-b` serves; job succeeds |
| UC4 | **Concurrency** — many jobs across zones at once | Isolated PDDs/artifacts; **one `meta.json` per UUID** (no shared-file race); per-node cap enforced by an atomic `flock` reservation (not a check-then-act race) |
| UC5 | **Control-plane ingress failover (Tier 1)** — one receptor sidecar down | Orchestrator fails its control socket over to the 2nd sidecar; nodes reconnect via it; new dispatch works. (Losing the orchestrator *host* is Tier 2.) |
| UC6 | **Third-party node (future)** — external team runs `exec-partner-*` | mTLS admits it (your CA signed it); work-signing means it *executes* but cannot *submit* |
| UC7 | **Direct legacy mode** — `make run PLAYBOOK=ping.yml` | Unchanged; does **not** traverse Receptor |
| UC8 | **Unauthorised node** — cert from unknown CA / wrong node id | Rejected by the controller |
| UC9 | **Target SSH failure** — bad/removed job SSH key | Receptor + Runner reach the node; SSH to target fails; job returns FAILED |
| UC10 | **Certificate rotation** — a node’s cert expires/rotates | Re-CSR → sign → install → reconnect, no CA-key exposure |

---

## 9. Verification & test mechanisms

### 9.1 Non-disruption checks (run every mesh PR)
The controller must be provably untouched:

```bash
# root controller files unchanged by a mesh PR
git diff --stat origin/main -- docker/ docker-compose.yml Makefile configs/ | \
  grep -q . && echo "controller touched — REVIEW" || echo "controller untouched"

# root compose starts the controller ONLY (the sidecar lives in the overlay, not root)
docker compose config --services            # expect: ansible   (no receptor-controller)
# the sidecar appears only when the overlay is loaded AND the profile is enabled:
docker compose -f docker-compose.yml -f mesh/compose.mesh.yml --profile mesh \
  config --services                         # expect: ansible + receptor-controller

# controller image identical posture (existing CI already asserts these)
#   - build + smoke test green (ansible --version, sshd running)
#   - Trivy CRITICAL/HIGH == 0 on amd64 AND arm64  (#55 gate)
```

### 9.2 Positive distributed-execution tests
```text
1. Prove the controller CANNOT reach the target directly (no route / SSH fails).
2. make mesh-run ZONE=net20 PLAYBOOK=ping.yml  → SUCCESS on the controller CLI.
3. "Prove-on-node" playbook returns the execution node's hostname/id, not the
   controller's (§25 of the source spec).
4. Correct Ansible exit code and artifacts returned to the controller.
```

### 9.3 Negative mTLS tests
Each must be **rejected** (encryption alone is not acceptance — both sides authenticate):
```text
- node with no certificate
- node cert signed by an unknown CA
- expired node certificate
- controller cert signed by an unknown CA   → node rejects controller
- node id ≠ certificate Receptor identity
- assert insecureskipverify / skipreceptornamescheck are NOT set in prod config
```

### 9.4 Target SSH negative test
```text
Remove/replace the job SSH credential, then mesh-run:
  Receptor connects ✓   Runner reaches node ✓   SSH to target FAILS ✓   job = FAILED
Proves Receptor identity and target SSH identity are separate.
```

### 9.5 Execution-node HA (failover)
```text
- Pool net20 = [exec-net20-a, exec-net20-b]; stop exec-net20-a.
- mesh-run ZONE=net20 → dispatcher selects exec-net20-b → SUCCESS.
- Assert: a job that had already STARTED on a node is NOT retried elsewhere
  (failover-boundary rule).
```

### 9.6 Concurrency / parallelism
```text
- Launch N concurrent mesh-run jobs across zones.
- Assert unique PDDs, unique artifact dirs, no work-unit id collision.
- Assert all N per-job meta.json files survive (one file per UUID; no shared-file
  corruption or lost entries).
- Per-node cap is enforced by an ATOMIC reservation: select+submit hold a `flock`
  on a per-node slot file (on shared storage), so the cap is not a check-then-act
  race on `receptorctl work list`.
- Assert the cap holds under a burst where every dispatcher sees a "free" slot at
  once — the surplus queues on the lock; they do not all submit to the same node.
```

### 9.7 Control-plane Tier 1 (ingress redundancy)
```text
- Control host runs TWO receptor sidecars (A, B); execution nodes peer to both.
- Orchestrator control socket targets A, with B configured as failover.
- Stop sidecar A → orchestrator fails over to B's control socket; nodes reconnect
  to B; mesh-status healthy; a FRESH dispatch succeeds through B.
- Out of Tier-1 scope: losing the orchestrator host itself → that is Tier 2.
```

---

## 10. Definition of done

- `make run` still executes directly (regression proven).
- `make mesh-run ZONE=net20 PLAYBOOK=ping.yml` runs on the node and returns rc + output.
- Controller has **no** direct network path to the target (proven).
- mTLS mutual, node-id checking on, `insecureskipverify` never set.
- No CA private key inside any runtime container.
- Execution-node HA: pool failover works (dispatch-only).
- Control-plane HA Tier 1: 2nd receptor sidecar + orchestrator control-socket failover works.
- Per-job `meta.json` written per UUID — concurrency-safe (Tier 2.5 enablement).
- Controller image scan == 0 CRITICAL/HIGH, both arches; existing pipeline untouched.
- No UI, API, database, broker, or scheduler introduced.
- Runbook documents: create / enroll / sign / install / start / verify / run /
  rotate / revoke / troubleshoot (mTLS, Runner, target SSH).

---

## 11. Explicitly deferred / non-goals

- **Tier 2 active/active orchestrators** — designed-for (stateless invariant), built when a real 2-host target exists.
- **Tier 2.5 in-flight recovery logic** — enabled by the per-job `meta.json` files; logic built with Tier 2.
- **Tier 3 stateful HA** — not built; if ever required, evaluate AWX.
- **Fan-out sharding** (one job split across nodes) — after single-job-to-pool is solid.
- **Auto-routing engine** (subnet → zone) — static `zones.yml` only, for now.
- **Publishing the node image** — until the flow is proven (Phase 11).
- No web UI, REST API, database, message broker, Kafka/RabbitMQ/ActiveMQ, Airflow,
  scheduler service, custom worker/enrollment/auth server.

---

## 12. Open decisions

1. **Local execution:** ship a colocated *local* execution node (so even local
   scans avoid the controller), or is legacy `make run` the local path and nodes
   are network-only initially?
2. **Deployment target for Tier 2:** two VMs, or an orchestrator (k8s)? Determines
   when/how Tier 2 becomes real.
3. **Command naming — RESOLVED.** Distributed jobs use
   **`make mesh-run ZONE=<zone> PLAYBOOK=<pb>`**, joining the existing `mesh-*`
   namespace (`mesh-up`, `mesh-down`, `mesh-status`, `mesh-ping`). `make run` stays
   as the direct/legacy path, unchanged. `ZONE` unifies local (`ZONE=local`) and
   network (`ZONE=net20`), so no separate verbs are needed; when auto-routing lands,
   `ZONE` becomes optional and is classified from `zones.yml` — no new verb.
   Rejected: `control-run` (the control plane does not execute) and `relay-run`
   (mislabels an execution node as a pass-through). The source spec’s
   `relay-run`/`RELAY=` may be kept as back-compat aliases if desired.
