# Execution-workflows design brief (prompt)

A reusable, repo-grounded prompt for designing the **execution workflows** of the
GitLab-CE → controller → mesh integration across **every deployment topology**,
each in **TLS and non-TLS** form, with the **correct credential at every hop**.

It is a *design brief*, not an authorization: running it produces designs,
diagrams, matrices, and — only within the scope already granted — implementation
and isolated tests. It does not authorize deploying a lab, publishing images, or
rotating operational credentials.

- **Design of record:** [ARCHITECTURE.md](ARCHITECTURE.md) — responsibilities,
  the 9-hop connection matrix, TLS modes A–E, failure/recovery, acceptance rows.
- **Integration point:** [bin/ctl-run](bin/ctl-run) — the one controller-side
  fetch-and-run command. **Env map:** [environments.example.yml](environments.example.yml).
- **Mesh dispatch:** [../mesh/bin/mesh-run](../mesh/bin/mesh-run). **HA tiers:**
  [../mesh/DESIGN.md](../mesh/DESIGN.md).

---

## The credential question, up front ("do we need an API token, or not?")

**No single universal API token — and the execution path must not use a broad
`api` PAT.** Scope credentials by purpose; this is already how the integration is
built, and the brief makes it a hard requirement:

| Purpose | Correct credential | Not |
|---|---|---|
| Runner requests pipeline jobs | Runner **authentication token** | a PAT |
| In-job GitLab API calls | auto-issued **`CI_JOB_TOKEN`** (dies with the job) | a long-lived token |
| `ctl-run` fetches the requested commit (controller-side, during the job) | read-only **deploy token** (`read_repository`) at `/etc/ctl-run/secrets/<env>.token` | `api` scope / a PAT / `CI_JOB_TOKEN` |
| External system starts a pipeline | **pipeline trigger token** (only if needed) | a deploy token |
| GitLab administration/automation | least-scope **API access token** | root/admin PAT for routine runs |
| CI → controller | **SSH key** (pinned host key, forced command) | password |
| Mesh transport | **mTLS node certificates** | shared secret |
| Mesh work authorization | **work-signing keypair** (ingress private, node public) | mTLS alone |
| Managed hosts | separate **SSH / WinRM / Vault** credentials | the controller-login key |

Hard rules the brief enforces: deploy ≠ trigger ≠ runner ≠ CI_JOB tokens (not
interchangeable); `ctl-run` fetches synchronously **during** the job; a controller-held deploy
token keeps repository access separate from CI job credentials; token values never in URLs, logs, artifacts, or Git remote config;
bootstrap admin credentials kept separate from runtime credentials and revoked
when done. Tokens authenticate/authorize; TLS protects the channel; neither
replaces the other, and GitLab's TLS mode never substitutes for Receptor mTLS +
work signing.

---

## How to use

Paste the block below into a capable coding agent working in this repository (or
follow it yourself). It expects the reader to *read the cited files first* and to
*label anything unproven* — DOCUMENTED / SIMULATED / UNTESTED — rather than assert
HA, WinRM, autoscaling, or enforced approval without test evidence.

---

## Prompt

````text
Act as a senior systems-design engineer and DevOps engineer. Produce the
EXECUTION-WORKFLOW design for this repository's GitLab-CE -> controller -> mesh
integration, covering every deployment topology, each in both TLS and non-TLS
form, with the correct credential at every hop. Design and document; implement
and test only what the authorization already covers. Do not claim HA, WinRM,
autoscaling, or enforced approval without test evidence -- label anything
unproven DOCUMENTED / SIMULATED / UNTESTED.

-- 0. GROUND IN THE REAL SYSTEM (read before designing) --
If available, load CLAUDE.local.md and the skills it names (gitlab-ce-automation,
ansible-mesh-architect); these developer-local resources are optional. Announce
which loaded and continue with the tracked files below when they are absent.
Read, and cite by path:
  gitlab/ARCHITECTURE.md, gitlab/README.md, gitlab/bin/ctl-run,
  gitlab/bin/ctl-shell, gitlab/environments.example.yml,
  gitlab/compose.gitlab.yml, gitlab/controller.override.yml, gitlab/setup.sh
  mesh/bin/mesh-run, mesh/DESIGN.md (HA tiers), mesh/RUNBOOK.md,
  mesh/EXTERNAL-CA.md, mesh/config/pools.yml, mesh/config/zones.yml
  mesh/labs/gitlab/ (compose, environments.yml, project-seed, scripts)
Reconcile the two integration models present: (A) CI job mounts Receptor sockets
and runs mesh-run itself -- the lab shortcut; (B) CI job -> SSH -> controller
ctl-run -> mesh-run -- the design of record. Baseline is B. Label any A-style
example as lab-only scope; never present it as the execution path. Treat every
existing PASS row as a historical claim until re-inspected.

-- 1. FIX THE BASELINE BEFORE ANY "SCALE"/"HA" CLAIM --
gitlab/bin/ctl-run holds a per-environment flock AND then refuses mesh dispatch
if ANY /var/lib/mesh/jobs/*/meta.json is non-final (created|submitting|running|
submit-ambiguous|results-incomplete). Show how that one guard blocks UNRELATED
environments and prevents idle nodes/pools from being used. Replace it with: a
durable per-logical-request identity; explicit retry-vs-new-execution semantics;
atomic admission; job ownership + state transitions; and locks scoped to the
ACTUAL protected resource (environment/target/mesh slot), not a global mesh-wide
refusal. Constraints that MUST survive: mesh dispatch-only failover, no automatic
resubmission after an ambiguous attempt, the pre-submit .hold, and per-node slot
admission. A commit SHA is not an idempotency key (schedules/manual re-runs of
the same SHA are legitimately distinct). A new CI job ID is not a dedup key for
retries. GitLab resource_group is project-scoped serialization, not a
cross-controller lock. flock files do not coordinate separate hosts.

-- 2. EXECUTION-WORKFLOW CASE MATRIX --
For EACH case produce: (i) a sequence diagram of the run; (ii) a direction
diagram showing who INITIATES each connection vs where work/results FLOW;
(iii) a per-hop credential+trust table; (iv) SPOFs, authoritative-state owner,
and recovery limits; (v) explicit acceptance criteria. Keep GitLab availability
separate from controller availability throughout -- one GitLab is a dependency
even when the controller tier is redundant.

  S1  Standalone, one controller:
      GitLab -> internal Runner -> SSH -> ctl-run -> ansible-playbook -> SSH/WinRM.
  S2  Mesh, one controller, ONE ingress:
      as S1 but ctl-run -> mesh-run -> ingress A -> node. Document explicitly as
      REDUCED-RESILIENCE (a manual/degraded config), not a packaged product.
  S3  Mesh, one controller, TWO ingresses (Tier-1, the built state):
      ctl-run -> mesh-run -> ingress A/B (control-socket failover) -> node(s).
      This is ingress redundancy, NOT controller-host HA -- state that plainly.
  S4  Multiple INDEPENDENT controllers (lab-* / prod-*):
      one central Runner; environment-scoped variables select the controller and
      its own environments.yml allowlist. Separate state, not HA.
  S5  Active/PASSIVE controllers (proposed): define authoritative-state location,
      config/PKI/credential consistency, admission ownership, FENCING, and the
      fate of ansible/mesh work already running on the failed host. Distinguish
      new-dispatch failover from recovery of existing jobs.
  S6  Active/ACTIVE controllers sharing nodes (proposed): treat as new
      distributed-systems work -- coordinated admission, durable execution
      ownership, duplicate-dispatch prevention, split-brain under partition.
      Do NOT build it to satisfy the list; give prerequisites + acceptance to
      defer it, and map DESIGN.md Tier-2/Tier-3 here (Tier-3 = adopt AWX, not a
      home-grown DB).
  H   Multiple Runners (orthogonal): separate new-job availability from recovery
      of jobs already assigned to a dead Runner. Runner redundancy is not
      controller HA.
Recommend a STAGED order (baseline -> S1/S3 -> S4 -> S5 -> S6). State which cases
are runnable in the disposable lab vs deferred with prerequisites.

-- 3. TLS / NON-TLS PER CONNECTION, APPLIED TO EACH CASE --
Use the 9-hop connection matrix already in gitlab/ARCHITECTURE.md as the spine.
For every hop show its OWN trust store (installing a CA for the Runner manager
does NOT configure job images, the controller git client, or registry pulls --
show each separately). Cover GitLab TLS modes:
  A public CA   B internal/corporate CA   C pinned self-signed (eval)
  D reverse-proxy termination (name the plaintext backend hop if any)
  E plain HTTP  (disposable isolated lab ONLY -- never a production variant)
State plainly per hop: HTTPS verifies server identity + encrypts; HTTP has no TLS
(tokens on it are exposed to that network); SSH is encrypted and verifies host
keys independently of TLS; Git-over-SSH does NOT protect the Runner's HTTP API
traffic; Unix sockets rely on local permissions; and GitLab's TLS mode NEVER
substitutes for mandatory Receptor mTLS + work signing. For the mesh hop give:
chain-to-mesh-CA, node-ID SAN 1.3.6.1.4.1.2312.19.1, dialed-hostname SAN, EKUs,
validity, key match, renewal -- and separate handshake verification from per-work
signature verification. CA private key stays offline. Do not present any
verification bypass (insecureskipverify, StrictHostKeyChecking=no) as a
production setting, and do not create a plaintext production mesh just because
GitLab runs HTTP in the lab.

-- 4. CREDENTIAL / TOKEN MODEL (scoped by purpose -- NO universal token) --
Produce a matrix: owner . consumer . purpose . MINIMUM scope . storage . lifetime
. rotation . revocation . transport . behavior-when-expired. Rows:
  Runner authentication token ................ Runner <-> GitLab (NOT a PAT)
  CI_JOB_TOKEN (auto) ........................ in-job only; EXPIRES with the job
  read-only deploy token (read_repository) ... ctl-run fetch; controller-held at
      /etc/ctl-run/secrets/<env>.token; CI never sees it. NOT `api`.
  pipeline trigger token ..................... only if external systems start
      pipelines; else omit
  API access token ........................... only for real GitLab API ops
      (admin/trigger); least scope; never root/admin for routine runs
  registry read credential ................... only if pulling private images
  Runner->controller SSH key ................. ed25519, env-scoped + protected CI
      variable; pinned known_hosts; forced command (ctl-shell)
  mesh TLS identities ........................ per-node key born on node
  work-signing keypair ....................... ingress holds private; node public
  target SSH / WinRM / Vault creds ........... selected by environments.yml,
      never by the caller
Hard rules: a deploy token is not API access; trigger != runner != deploy !=
CI_JOB tokens are not interchangeable; ctl-run fetches synchronously DURING the
job, but uses a controller-held deploy token to isolate repository credentials
from CI; keep token values out of URLs, logs, artifacts, and Git
remote config (use a credential helper / user:token file, not the query string);
separate BOOTSTRAP admin creds from RUNTIME creds and revoke bootstrap when done.
Verify token types + API endpoints against the installed GitLab CE version.

-- 5. SSH AND WINRM TARGETS IN EVERY CASE --
Both standalone and mesh must support SSH (verified host keys) and WinRM-HTTPS
:5986 (cert + hostname validation); document WinRM-HTTP :5985 with message
encryption separately (not HTTPS-equivalent; never Basic-over-HTTP). Note that
--ssh-key cannot supply WinRM creds, that the node has no controller /configs
mount. Install ansible.windows at the executing runtime; in mesh mode, use
galaxy_dir to stage the collection for the node, per environments.example.yml.
Provision the Vault password separately on the controller in standalone mode
and on the node in mesh mode; galaxy_dir does not stage Vault passwords.
Test a real Windows host if available; else mark WinRM
UNTESTED (as the acceptance matrix already does).

-- 6. FAILURE / RECOVERY HONESTY (per case) --
Exercise or analyze: GitLab down; Runner lost before/after ctl-run; controller
crash during fetch/submit; ingress loss; node loss/partition; target SSH/WinRM
failure; expired/revoked credential; stream interruption; CI cancel/timeout/retry.
Preserve submit-ambiguous and results-incomplete as UNKNOWN -- absence of a unit
from a current ingress work-list does NOT prove it never ran; a second ingress
need not hold the first's unit record. --collect recovers results without
re-execution; never clear a .hold or mark a job failed just to free capacity.
Return the real Ansible rc when known; distinguish it from transport/collection
errors. Reverting code does not undo target changes.

-- 7. DELIVERABLES --
Separate readable Mermaid diagrams (not one mega-diagram): S1; S2 (one ingress,
REDUCED-RESILIENCE); S3; S4; S5 and S6 clearly labeled PROPOSED; H (multiple
Runners, with assigned-job recovery limits); outbound Runner-poll + returned-job delivery;
node-dials-out vs signed-work-delivered-inward; project lifecycle; credential/CA
distribution; retry/cancel/recovery. Plus: the scenario support matrix; the
connection (TLS) matrix; the credential matrix; the concurrency-fix design with
acceptance criteria; updated gitlab/ARCHITECTURE.md + operator docs; reproducible
lab setup + scoped teardown reusing mesh/tests + mesh/labs/gitlab; results marked
PASS / FAIL / BLOCKED / UNTESTED with evidence; known gaps + prioritized
follow-ups; and official GitLab/Ansible citations for any version-specific claim.
Do not modify live infrastructure, publish images, or rotate operational
credentials beyond the authorization given.
````

---

## Steering notes (senior-engineer emphasis)

- **Fix §1 before any HA case.** The coarse mesh guard in `ctl-run` — a global
  refusal on *any* non-final `meta.json` — is the real blocker to using more than
  one node/environment at once. HA layered on top of global serialization is
  theater.
- **S5/S6 are genuinely new distributed-systems work.** Active/passive needs
  fencing and a decision on the in-flight jobs of the dead host; active/active
  needs durable cross-host admission and split-brain handling.
  [../mesh/DESIGN.md](../mesh/DESIGN.md) already (correctly) defers these to
  Tier 2/3 and says Tier 3 = adopt AWX rather than build a database. Keep that
  honesty; do not build HA merely to complete the list.
- **The TLS matrix is per-hop, not per-system.** The most common mistake is "we
  set the Runner's CA, so TLS is done." Each of the job image, the controller Git
  client, and the registry has its own trust store.
- **Keep GitLab availability separate from controller availability.** A single
  GitLab remains a dependency even when the controller tier is redundant.
