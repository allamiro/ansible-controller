# Distributed Execution Mesh — Design & Implementation Plan

> **Status: PLAN. Nothing here is implemented yet.** This directory is a review
> artifact. It describes how distributed Ansible execution and control‑plane HA
> will be added to this repository *without changing the existing controller
> image or its behaviour*. Code lands only after this plan is approved, one
> phase per PR.

---

## 0. Purpose

Add a second execution path to the existing Ansible controller:

- **Direct (existing):** `make run` — the controller executes Ansible itself. Unchanged.
- **Distributed (new):** work is dispatched to **execution nodes** grouped into
  **pools per zone**. The controller becomes an *orchestrator*; execution happens
  on the nodes, not on the controller.

The mesh differentiates **local** targets (a directly‑reachable zone) from
**network** targets (segmented zones reachable only through a node), and provides
HA at two independent layers: **execution‑node pools** and the **control plane**.

Built on **Receptor + Ansible Runner + mTLS** only. No web UI, REST API, database,
message broker, or scheduler service — see [§11 Non‑goals](#11-explicitly-deferred--non-goals).

---

## 1. Non‑disruption guarantees (how the existing controller is protected)

These are load‑bearing. The existing controller must be provably unchanged until
an operator opts in.

| # | Guarantee | Enforced by |
|---|-----------|-------------|
| 1 | Root `docker-compose.yml`, `Makefile` direct targets, `docker/Dockerfile` output all stay identical | Mesh lives in `mesh/`; controller image proven byte/scan‑identical (see [§9.1](#91-non-disruption-checks-run-every-mesh-pr)) |
| 2 | `make up` / `make down` / `make run` behave exactly as today | Sidecar and nodes are **Compose‑profile‑gated** (`--profile mesh`); default `up` never starts them |
| 3 | The controller build context is unchanged | `mesh/` is excluded via `.dockerignore` |
| 4 | The release pipeline (#54–#57: cosign, semver, Trivy gate) is untouched | Node/relay images are **not** added to `docker-publish.yml` until a deliberate later phase |
| 5 | The CVE posture stays clean | Shared runtime carries the existing pip‑vendor patch + pebble removal; every mesh image is scanned by the same gate before it can publish |

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

- **Execution‑node HA** — multiple nodes per zone; dispatch fails over between them.
- **Control‑plane HA** — see [§3](#3-ha-decisions-agreed). Tier 1 (ingress
  redundancy) is native to Receptor; Tier 2 (active/active orchestrators) is
  designed‑for but built later.

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
                       └────────┬────────┘   zones/pools, job-index.json
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
     ├─(5) record job-index.json entry {job-id, node, status=dispatching}
     ├─(6) ansible-runner transmit → receptorctl work submit --node exec-net20-a
     │        │
     │        ├─ node accepts + worker STARTS ──►  ⛔ FAILOVER BOUNDARY
     │        │       from here: on failure → REPORT, never retry elsewhere
     │        │       (re-running a partial mutating play can double-apply)
     │        │
     │        └─ unreachable / rejected BEFORE start
     │                 └─ failover → exec-net20-b   ✅ safe (nothing ran)
     ├─(7) stream events → ansible-runner process ; update job-index status
     ├─(8) artifacts → logs/runner/<job-id>/  (stdout, rc, job_events)
     └─(9) return Ansible rc
```

**The failover boundary is the most important correctness rule in this design.**
Failover happens only *before* a worker starts. Once Ansible is applying changes,
a failure is reported, never silently retried on another node.

---

## 3. HA decisions (agreed)

| Tier | What | Decision |
|------|------|----------|
| **1** | N Receptor ingress nodes; execution nodes multi‑peer with redial | **Build now.** Native, cheap, real. |
| **2** | Active/active orchestrators (VIP/DNS, shared config+PKI, git playbooks) | **Design for it, build when a real 2‑host target exists.** Interim recovery = documented fast orchestrator restart (state is external, so seconds). |
| **2.5** | Recover an in‑flight job’s live stream onto the surviving orchestrator | **Don’t build the recovery logic.** But write `job-index.json` now (for status/history) so the logic is nearly free later. Meaningless until Tier 2 exists. |
| **3** | Full stateful HA (real state store) | **Don’t.** That store is a database; if ever truly required, evaluate adopting **AWX** instead of reimplementing it. |

**In‑flight failure posture (interim):** if an orchestrator dies mid‑job, the job
keeps running on the execution node (Receptor is store‑and‑forward); the live
stream is lost; recovery is re‑query artifacts or re‑run (playbooks are idempotent).

---

## 4. Day‑one invariants (make HA cheap later, cost ~0 now)

Hold these from the first mesh commit even in the single‑orchestrator build:

| Invariant | Why | Cost now |
|-----------|-----|----------|
| Orchestrator holds **no local‑only state** — all state on mountable/shared storage or git | One→two orchestrators becomes config, not a rewrite | discipline only |
| Every job gets a **stable UUID** and a **`job-index.json`** entry | Status/history today; Tier 2.5 recovery later | small; wanted anyway |
| Execution nodes peer to a **list** of ingress addresses (even a list of one) | Tier 1 becomes "add controller‑B to the list" | ~0 |
| CA private key **never** on a runtime container | CA is not a runtime SPOF; signing is offline | ~0 |

---

## 5. Directory layout

Everything lives under `mesh/`. Image builds stay in `docker/` as multi‑stage
targets so the CVE remediation has a single home (no dependency drift).

```text
ansible-controller/
├── docker/
│   └── Dockerfile              # multi-stage: ansible-runtime (base) → controller
│                               #   (unchanged output; adds a shared base stage)
├── docker-compose.yml          # UNCHANGED — controller only
├── Makefile                    # existing targets untouched; mesh targets appended
│
└── mesh/                       # ← the whole subsystem, isolated
    ├── README.md               # this document
    ├── compose.mesh.yml        # overlay: sidecar + local exec-node, profile-gated
    ├── images/
    │   └── execution-node/
    │       ├── Dockerfile       # FROM ansible-runtime (no sshd, no port 22)
    │       └── entrypoint.sh    # renders receptor node config from env
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
| 0 | SSH hardening: add managed `known_hosts` / strict path, label dev override; **do not flip default** | Config only, opt‑in | Existing direct run still works with current default |
| 1 | Dockerfile refactor: introduce `ansible-runtime` base; `controller` target = today | Build only, output identical | Smoke test + Trivy = 0, both arches ([§9.1](#91-non-disruption-checks-run-every-mesh-pr)) |
| 2 | Add `ansible-runner` + `receptorctl` to controller (pure‑Python, additive) | Yes, additive | Smoke green; scan still 0 |
| 3 | `receptor-controller` sidecar + shared socket volume, **profile‑gated** | No (opt‑in) | `make up` unchanged |
| 4 | Execution‑node image (`FROM ansible-runtime`) + test lab, **no TLS (dev only)** | No | Local build only; never published |
| 5 | Prove `transmit → work submit → worker → process` across the mesh | No | Positive tests [§9.2](#92-positive-distributed-execution-tests) |
| 6 | PKI scripts + **mandatory mTLS** (Tier‑1 multi‑ingress design) | No | Negative mTLS tests [§9.3](#93-negative-mtls-tests) |
| 7 | Target SSH credential handling + artifacts + `job-index.json` | No | SSH‑negative test [§9.4](#94-target-ssh-negative-test) |
| 8 | Pools + failover dispatcher (execution‑node HA) + concurrency caps | No | HA + concurrency tests [§9.5](#95-execution-node-ha-failover)/[§9.6](#96-concurrency--parallelism) |
| 9 | Work signing (`--signwork`) — authorises the future third‑party boundary | No | Signed‑work test; unsigned rejected |
| 10 | Makefile convenience targets + docs/runbook | Appends only | Existing targets still work |
| 11 | *(optional, later)* publish + cosign + scan node image | Release pipeline | Extend the matrix, don’t fork it |
| — | **Deferred:** Tier 2 active/active; fan‑out sharding; auto‑routing engine | — | Built only when a real driver exists |

---

## 7. To‑do checklist

### Phase 0 — SSH hardening (independent, can ship first)
- [ ] Add a managed `known_hosts` mechanism + `StrictHostKeyChecking=yes` path
- [ ] Clearly label the existing lax settings as **dev‑only** override
- [ ] Document; do **not** change the current default (flip only at a major bump)

### Phase 1 — runtime base stage
- [ ] Split `docker/Dockerfile` into `ansible-runtime` → `controller`
- [ ] Move pip‑vendor patch + pebble removal into `ansible-runtime`
- [ ] Prove controller image smoke + Trivy = 0 on amd64 **and** arm64

### Phase 2 — controller orchestration deps
- [ ] `pip install ansible-runner receptorctl` in the runtime stage
- [ ] Confirm no entrypoint/sshd behaviour change; scan still 0

### Phase 3 — controller receptor sidecar
- [ ] `mesh/config/receptor/controller.yml` (v2, Unix control socket, no TCP control)
- [ ] `mesh/compose.mesh.yml` with `receptor-controller` under `profiles: [mesh]`
- [ ] Shared named volume `receptor-runtime:/run/receptor`
- [ ] Verify `make up` still starts controller **only**

### Phase 4 — execution node + dev lab
- [ ] `mesh/images/execution-node/Dockerfile` (`FROM ansible-runtime`, no sshd)
- [ ] `mesh/images/execution-node/entrypoint.sh` (render node config from env)
- [ ] `mesh/tests/` multi‑network compose lab (controller cannot reach targets)
- [ ] **No‑TLS** dev mesh to prove wiring (never in a production compose file)

### Phase 5 — prove distributed execution
- [ ] `mesh/bin/mesh-run` (minimal: transmit → submit → worker → process)
- [ ] Positive test: controller can’t SSH target directly; `mesh-run` succeeds
- [ ] "Prove‑on‑node" playbook shows node id, not controller

### Phase 6 — PKI + mandatory mTLS
- [ ] `mesh/pki/`: `mesh-ca-init.sh`, `controller-cert.sh`, `node-csr.sh`, `node-sign.sh`
- [ ] Idempotent CA init (STOP if CA exists unless `--force`)
- [ ] Node‑id ⇄ cert identity checking on; `insecureskipverify` never set
- [ ] Multi‑ingress peer list (Tier 1) in the node template
- [ ] All negative mTLS tests pass

### Phase 7 — credentials, artifacts, job index
- [ ] `env/ssh_key` in the transmit payload; never logged/echoed
- [ ] Artifacts to `logs/runner/<job-id>/` (stdout, rc, job_events)
- [ ] Write `job-index.json` entry per job (day‑one invariant)
- [ ] Secure cleanup of transient key copies

### Phase 8 — pools, failover, concurrency
- [ ] `mesh/config/zones.yml` + `pools.yml`
- [ ] Dispatcher: classify → healthy‑node select → submit → **dispatch‑only failover**
- [ ] Per‑node concurrency cap via `receptorctl work list`
- [ ] Unique PDD + artifact dir + work‑unit id per concurrent job

### Phase 9 — work signing
- [ ] Controller work‑signing private key (offline‑issued); relay verification pubkey
- [ ] `verifysignature: true` on node worktype; submit with `--signwork`
- [ ] Test: unsigned work rejected

### Phase 10 — Make targets + docs
- [ ] `mesh-up`, `mesh-down`, `mesh-status`, `mesh-ping`, `mesh-run`
- [ ] Runbook: create/enroll/sign/install/verify/run/rotate/revoke/troubleshoot
- [ ] Confirm every pre‑existing Make target still works

---

## 8. Use cases

| UC | Scenario | Expected outcome |
|----|----------|------------------|
| UC1 | **Local scan** via colocated local execution node | Runs on `exec-local-*`, not on the controller |
| UC2 | **Network scan** into segmented `net20` | Runs on `exec-net20-*`; controller has no route to the target |
| UC3 | **Execution‑node failover** — `exec-net20-a` down at dispatch | `exec-net20-b` serves; job succeeds |
| UC4 | **Concurrency** — many jobs across zones at once | Isolated PDDs/artifacts; per‑node cap respected |
| UC5 | **Control‑plane ingress failover (Tier 1)** — controller receptor A down | Nodes stay connected via B; mesh‑status healthy; new dispatch works |
| UC6 | **Third‑party node (future)** — external team runs `exec-partner-*` | mTLS admits it (your CA signed it); work‑signing means it *executes* but cannot *submit* |
| UC7 | **Direct legacy mode** — `make run PLAYBOOK=ping.yml` | Unchanged; does **not** traverse Receptor |
| UC8 | **Unauthorised node** — cert from unknown CA / wrong node id | Rejected by the controller |
| UC9 | **Target SSH failure** — bad/removed job SSH key | Receptor + Runner reach the node; SSH to target fails; job returns FAILED |
| UC10 | **Certificate rotation** — a node’s cert expires/rotates | Re‑CSR → sign → install → reconnect, no CA‑key exposure |

---

## 9. Verification & test mechanisms

### 9.1 Non‑disruption checks (run every mesh PR)
The controller must be provably untouched:

```bash
# root controller files unchanged by a mesh PR
git diff --stat origin/main -- docker/ docker-compose.yml Makefile configs/ | \
  grep -q . && echo "controller touched — REVIEW" || echo "controller untouched"

# default compose starts the controller ONLY (sidecar is profile-gated)
docker compose config --services            # expect: ansible   (no receptor-controller)
docker compose --profile mesh config --services   # expect: + receptor-controller

# controller image identical posture (existing CI already asserts these)
#   - build + smoke test green (ansible --version, sshd running)
#   - Trivy CRITICAL/HIGH == 0 on amd64 AND arm64  (#55 gate)
```

### 9.2 Positive distributed‑execution tests
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

### 9.5 Execution‑node HA (failover)
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
- Assert per-node concurrency cap holds (extra jobs queue, not overrun).
```

### 9.7 Control‑plane Tier 1 (ingress redundancy)
```text
- Two receptor ingress nodes; execution nodes peer to both (redial).
- Stop ingress A → nodes reconnect via B within redial interval.
- mesh-status still healthy; a fresh dispatch succeeds through B.
```

---

## 10. Definition of done

- `make run` still executes directly (regression proven).
- `make mesh-run ZONE=net20 PLAYBOOK=ping.yml` runs on the node and returns rc + output.
- Controller has **no** direct network path to the target (proven).
- mTLS mutual, node‑id checking on, `insecureskipverify` never set.
- No CA private key inside any runtime container.
- Execution‑node HA: pool failover works (dispatch‑only).
- Control‑plane HA Tier 1: ingress redundancy works.
- `job-index.json` written per job (Tier 2.5 enablement).
- Controller image scan == 0 CRITICAL/HIGH, both arches; existing pipeline untouched.
- No UI, API, database, broker, or scheduler introduced.
- Runbook documents: create / enroll / sign / install / start / verify / run /
  rotate / revoke / troubleshoot (mTLS, Runner, target SSH).

---

## 11. Explicitly deferred / non‑goals

- **Tier 2 active/active orchestrators** — designed‑for (stateless invariant), built when a real 2‑host target exists.
- **Tier 2.5 in‑flight recovery logic** — enabled by `job-index.json`; logic built with Tier 2.
- **Tier 3 stateful HA** — not built; if ever required, evaluate AWX.
- **Fan‑out sharding** (one job split across nodes) — after single‑job‑to‑pool is solid.
- **Auto‑routing engine** (subnet → zone) — static `zones.yml` only, for now.
- **Publishing the node image** — until the flow is proven (Phase 11).
- No web UI, REST API, database, message broker, Kafka/RabbitMQ/ActiveMQ, Airflow,
  scheduler service, custom worker/enrollment/auth server.

---

## 12. Open decisions

1. **Local execution:** ship a colocated *local* execution node (so even local
   scans avoid the controller), or is legacy `make run` the local path and nodes
   are network‑only initially?
2. **Deployment target for Tier 2:** two VMs, or an orchestrator (k8s)? Determines
   when/how Tier 2 becomes real.
3. **Command naming — RESOLVED.** Distributed jobs use
   **`make mesh-run ZONE=<zone> PLAYBOOK=<pb>`**, joining the existing `mesh-*`
   namespace (`mesh-up`, `mesh-down`, `mesh-status`, `mesh-ping`). `make run` stays
   as the direct/legacy path, unchanged. `ZONE` unifies local (`ZONE=local`) and
   network (`ZONE=net20`), so no separate verbs are needed; when auto‑routing lands,
   `ZONE` becomes optional and is classified from `zones.yml` — no new verb.
   Rejected: `control-run` (the control plane does not execute) and `relay-run`
   (mislabels an execution node as a pass‑through). The source spec’s
   `relay-run`/`RELAY=` may be kept as back‑compat aliases if desired.
