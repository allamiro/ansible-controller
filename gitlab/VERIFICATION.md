# GitLab integration verification — 2026-09-08

**Verdict: the core GitLab-driven standalone and mesh workflows work, but the
complete requested architecture is not implemented.** Independent controllers
and redundant mesh ingress are not highly available controller scheduling.
Windows, full controller HA, autoscaling and every certificate mode cannot be
certified from this Docker/Linux environment.

Tests used a new, isolated `gitlab-audit` Compose deployment, GitLab **Community
Edition 19.3.1** and Runner **19.3.1**. Existing controller, GitLab lab and mesh
e2e services were left running. The version was checked against the running API
and the [official 19.3.1 patch release](https://docs.gitlab.com/releases/patches/patch-release-gitlab-19-3-1-released/).
This is a latest-stable check as of this date, not a promise that the pin stays
current. Ansible development images already available locally were reused;
current `ctl-run` and `mesh/bin` were bind-mounted into the audit controller.

## Final independence check and teardown

After stopping the audit GitLab server, Runner and HTTPS gateway, native
`ansible-playbook` execution on the controller and native `mesh-run` execution
through its node both completed successfully (rc 0). These checks used local
project files already on the controller, with no GitLab fetch or token-dependent
execution step. Windows transport is still outside this test's coverage.

At the user's request, the `gitlab-audit` Compose containers, networks and volumes
were removed after testing. Docker label checks found no remaining Compose
resources for that project. Existing `ansible-controller`, `gitlab-lab` and
`mesh-e2e` services were preserved. The recorded pipeline IDs now identify
historical evidence; their disposable GitLab instance is no longer available.
Sanitized evidence and private local test traces remain in the workspace;
controller/GitLab volume contents were deleted. Before rebuilding this lab,
archive any needed traces and reset its `.state` fixtures as described in the
test README, because the old bootstrap markers no longer match any database.

## What actually ran

| Case | Observed result / evidence |
|---|---|
| Standalone controller, Linux SSH targets, GitLab private CA | PASS, pipeline 3/job 3; pinned target SSH trust and real target marker |
| Plain HTTP project fetch, standalone | PASS, pipeline 4/job 4; lab-only plaintext GitLab hop, SSH remains encrypted |
| Intentional standalone playbook failure | PASS negative, pipeline 5/job 5 failed with Ansible error |
| Single controller + execution node, mTLS mesh | PASS, pipeline 6/job 6 |
| Intentional mesh playbook failure | PASS negative, pipeline 7/job 7 failed |
| Ingress A stopped, B still available before dispatch | PASS, pipeline 8/job 8; A restored afterward |
| Second independent controller, same central Runner | PASS, pipeline 16/job 26; separate controller state volumes |
| Unknown environment | PASS negative, pipeline 17/job 27 refused |
| Invalid repository fetch credential | PASS negative, pipeline 18/job 28 refused |
| Execution node unavailable before dispatch | PASS negative, pipeline 19/job 29 failed; original pre-submit state retained |
| Node restored | PASS, pipeline 20/job 30 |
| Actual repository seed CI YAML | GitLab CI lint valid, no warnings/errors; validation job 9 passed |
| Feature branch → MR validation → merge | PASS, MR !1 in audit-lifecycle; MR pipelines 11/12 contain only validation |
| Manual mesh deployment after merge | PASS, pipeline 13/job 17 |
| Scheduled mesh check | PASS, pipeline 14/job 23; schedule left inactive |
| Developer direct push to protected main | Rejected HTTP 403; temporary developer API token revoked |
| Trigger token without explicit confirmation | Pipeline 21 has no automatic api-deploy job |
| Trigger token + DEPLOY_CONFIRM=yes | PASS, pipeline 22/job 38; trigger token revoked after test |
| Protected tag and manual release | PASS, pipeline 23/job 41 |
| Seed collection job through SSH | PASS, pipeline 22/job 39; terminal collection does not resubmit |
| Actual seed standalone manual job | PASS, pipeline 22/job 37 |
| Dispatcher interrupted while streaming | Bug reproduced in pipeline 24/job 42; fixed state transition verified in pipeline 25/job 43 |
| Collection after interrupted streaming | PASS: same UUID `af3d0981-14b6-438d-b90a-7c2f276b1029`, results-incomplete → succeeded, no resubmission |
| CA verification | Trusted private CA accepted; absent CA and wrong TLS hostname rejected |
| SSH channel verification | Unknown host key rejected; forced command rejects `id` |
| GitLab network isolation | GitLab cannot open controller TCP/22 using its actual control-network IP |
| Local regression tests | Six tests pass: symlink escape, nested LFS, staging permissions, project working directory, real failure rc, malformed audit ID |

Pipeline/job numbers belong to the disposable instance, not the existing lab.
Machine-readable sanitized results are in [tests/evidence.json](tests/evidence.json).
Raw traces, CA files and credentials remain under the gitignored `tests/.state`.
See [test instructions](tests/README.md) for reproducible commands.

## How execution works

1. A developer creates/changes project files on a branch. Unprotected validation
   runs without deployment keys, on a network that does not reach controllers.
2. Reviewed changes merge to protected main. A manual release, schedule or
   explicitly confirmed token-triggered pipeline selects a protected job.
3. Runner manager asks GitLab for work. Its deployment job opens SSH to the
   controller; GitLab itself does not need to dial the controller or nodes.
4. The forced SSH command invokes `ctl-run`. The controller's administrator-owned
   environment mapping decides project allowlist, GitLab URL, inventory, target
   credential, execution mode and mesh destination. The controller fetches the
   requested immutable SHA with a read-only deploy token.
5. Standalone runs `ansible-playbook` from the fetched project root. Mesh runs
   `mesh-run`; signed work travels through Receptor to the node over mesh mTLS.
   The execution node runs Ansible against its reachable target network.
6. Output and exit status return over the controller SSH channel to the GitLab
   job. Detailed mesh artifacts and audit metadata remain on the controller.
   Recovery uses `ctl-run --collect <original-uuid>`, not another submission.

There is **no controller HTTP API** here, so no controller API token is required.
Authentication is separate per hop: Runner token for scheduling; ephemeral
`CI_JOB_TOKEN` for Runner checkout; read_repository deploy token for controller
fetch; SSH key for controller invocation; mesh identity certificates and work
signatures; SSH keys or WinRM credentials for targets. A GitLab API/PAT is needed
for provisioning/API operations, and a trigger token for the trigger endpoint.
Neither is a replacement for the controller's SSH key or repository credential.

## Fixes made during this review

- `ctl-run` now honors the fetched project's working directory and ansible.cfg.
- Staging starts private (`umask 077`). External/dangling/cyclic project symlinks
  are rejected before provenance writes; a reproducer previously overwrote a
  controller file through a committed symlink. Nested submodules/LFS metadata
  are also rejected rather than silently mishandled.
- Administrator-owned `git_ca_file` supports private-CA Git fetch even when the
  forced-command sudo boundary strips the caller's environment. This configures
  Git trust only; it does not configure WinRM or mesh trust.
- Numeric audit IDs are checked without unsafe shell word splitting.
- Mesh wrapper status follows authoritative mesh state instead of always
  recording `finished`. Missing output no longer guesses a job identity from a
  matching basename and timestamp.
- Removed automatic stage deletion: successful later jobs could remove evidence
  belonging to unresolved work. Operators need an explicit disk/retention policy.
- `mesh-run` now publishes its UUID before submission and converts catchable
  dispatcher exits from `running` to `results-incomplete` (or `submitting` to
  `submit-ambiguous`). The hold remains. Previously a terminated dispatcher left
  a stale `running` record that blocked collection. The initial reproduced orphan
  was recovered by correcting only its fixture state after confirming its
  dispatcher was gone; the subsequent run recovered using the fixed code.
- Seed collection now uses the same pinned SSH/controller channel as dispatch.
  New deployment Runner registrations no longer mount mesh sockets/state or
  target keys; installer logic detects legacy mesh-volume registrations.
- Setup preserves the running controller's Compose file stack instead of
  silently replacing mesh overlays with the base standalone definition. This
  installer change passed static checking; the active user's controller was
  not recreated to test an installer upgrade.
- Corrected the recovery instruction that treated “unit absent” as proof it did
  not execute. Absence is UNKNOWN; it does not authorize clearing a hold/retry.

ShellCheck at warning severity and `git diff --check` pass (the mesh script
retains its pre-existing SC1007 empty-assignment style warnings, excluded from
that check). The changes do not
make execution of malicious playbooks safe: the deployment key grants powerful
controller execution authority. CI YAML, playbooks, inventory plugins and project
ansible.cfg require the same trusted-author review.

## Remaining requirements and limits

| Requirement | Status / next necessary work |
|---|---|
| Standalone HA / active-passive controller failover | NOT IMPLEMENTED. Need durable shared request state, ownership/fencing, storage/credential recovery and an actual failover test. Two independent controllers do not provide it. |
| Active-active controller mesh scheduler | NOT IMPLEMENTED. Host-local flock and records are not distributed leases. Do not put identical schedulers behind a load balancer and claim exactly-once execution. |
| Automatic execution-node scaling | NOT IMPLEMENTED. Enrollment and pool selection exist; dialing an ingress does not provision, authorize, add capacity policy, drain or delete nodes. |
| Multi-node pool/zone capacity matrix | Existing mesh mechanisms; this GitLab audit exercised one execution node, not every pool/zone/capacity permutation. |
| Durable logical-request deduplication | NOT IMPLEMENTED. The per-environment lock and global unresolved-mesh-job guard are coarse. A completed or standalone deployment can execute again on CI retry. Need an immutable logical request ID and persisted claim/result before dispatch. |
| Concurrent unrelated deployments | LIMITED. One unresolved mesh job blocks other mesh environments on that controller; fix together with request ownership, not by deleting the guard. |
| Proving SHA was approved | LIMITED. Exact requested SHA is fetched, but ctl-run does not query GitLab to establish protected-ref/review membership. Caller-supplied pipeline/job IDs are audit hints, not independently verified authorization. |
| Mandatory multi-approver approval | NOT native CE enforcement. [GitLab Free approvals are optional](https://docs.gitlab.com/user/project/merge_requests/approvals/). Protected refs and restricted merge rights are the tested gate; stronger approval requirements need a separate enforceable control or another edition. |
| Windows SSH / WinRM 5986 and 5985 | NOT LIVE TESTED: no Windows host supplied. Linux containers cannot validate Windows authentication, Kerberos/SPNs, certificate trust or message encryption. WinRM needs credentials, collection availability, and CA trust at the actual executing node/controller. |
| Public-CA GitLab | NOT LIVE TESTED: no owned public DNS/certificate configured. |
| Pinned self-signed leaf, expired certificates, CA rotation, end-to-end proxy TLS | NOT LIVE TESTED. Tested private CA + TLS proxy termination with plaintext isolated upstream. That is not TLS encryption on the upstream hop. |
| “No SSL” mesh | Intentionally unsupported: HTTP GitLab does not disable mesh mTLS, SSH host verification or work signatures. |
| Ambiguous submit after lost response | Must stay UNKNOWN. Recovery of a known unit and ingress loss are narrower tests; they do not prove every submit/crash/network partition timing. |
| Controller restart mid-job, data loss, disaster restore | NOT TESTED in this audit; requires durable idempotency/fencing design and restore fixtures. |
| GitLab artifact presentation | PARTIAL: console output/status is visible; full controller artifacts are not exported by the seed workflow. Add a constrained read-only artifact retrieval contract, not mesh volumes in CI. |
| Complete project tree in mesh execution | LIMITED: mesh packaging uses the playbook directory; sibling root roles/config/resources need explicit packaging. Standalone now uses project-root configuration. |
| Installer coverage | Isolated fixture bootstrap tested. Existing-environment migration, every installer parameter, certificate provisioning and bootstrap-token revocation failure paths are not fully exercised. |

These are not resolved by more Docker containers alone. The next architectural
change should implement logical request identity and durable ownership, then
exercise independent-controller and real HA failure matrices. A Windows test
host and certificate fixtures are required to complete the remaining transport
matrix. Existing lab “PASS” claims in other documents are historical evidence,
not substitutes for these explicit coverage limits.
