# Reviewed mesh sync, execution and results

For fleets of 100 or more systems, keep two decisions separate: review the code
before it reaches deployment staging, then authorize its execution against an
environment. Fleet size does not introduce a license requirement.

## Approval flow

1. Validate a merge request without deployment credentials. A trusted Maintainer
   reviews and merges into protected `main` (or creates a protected release tag).
2. The protected **sync** job fetches that exact Runner checkout SHA into a private
   controller directory. It validates the tree and records the commit subject,
   inventory path, configured node/pool/zone, pipeline and sync job. It does not
   run Ansible, evaluate inventory plugins, install project dependencies, or submit
   mesh work. Review its restricted `reports/summary.html` or `summary.json`.
3. A release operator manually starts the matching **deploy** job. The controller
   checks that the staged files and administrator environment mapping still match
   the sync receipt, then executes those bytes without fetching Git again. The
   existing request journal prevents a job Retry from executing completed or
   uncertain work twice.
4. Inspect the deployment result and final recap. Collect incomplete results from
   the original mesh UUID; never assume a disconnected CI job stopped the targets.

The project template names its jobs `sync` and `deploy`. The bootstrap seed has
matching `sync-deploy-mesh`, `sync-scheduled-check`, `sync-api-deploy` and
`sync-tag-deploy` jobs. Its standalone `deploy-direct` route remains one manual
fetch-and-run operation. All mesh execution routes remain manual.

For a separate human approval **before syncing**, add `when: manual` and
`allow_failure: false` to each desired sync job rule. Keep its matching deployment
job manual and dependent on that sync job. This gives two explicit buttons.
Neither button establishes independent reviewer identity: GitLab CE uses protected
refs, runners/variables, trusted Maintainer review and manual release. Enforced
reviewer counts require separately configured licensed policies; see
[optional approval policies](OPTIONAL-APPROVALS.md).

## Controller contract and upgrade

Deploy the complete matching `gitlab/bin/` directory before updating a project.
Bootstrap preserves populated repositories: update `.gitlab-ci.yml` and
`scripts/ctl-ci.sh`, `scripts/deploy.sh`, `scripts/report.py` through review.
Set `require_sync: true` in each administrator-owned mesh environment to reject
legacy combined fetch-and-run invocations. The example `prod-mesh` enables it.
Native mesh CLI jobs are outside this GitLab wrapper policy and remain available;
the deployment key itself carries authority, so this is not a sandbox for an
operator who can change controller configuration or protected pipeline code.

For the same `--env`, `--project`, `--sha`, `--playbook` and `--pipeline` arguments:

- `ctl-run --sync-only ...` stages and records a snapshot without execution.
- `ctl-run --sync-only --artifacts ...` exports that sync receipt.
- `ctl-run --execute-synced ...` requires a matching snapshot and checks it again.
- `ctl-run --artifacts ...` exports the execution record and available results.

`--job` differs between sync and execution; both IDs appear in execution reports.
The request identity binds one pipeline to one commit. Changed files, changed
permissions, replaced links or a changed environment mapping refuse execution.
Use a new reviewed pipeline to sync again; do not edit receipts to bypass refusal.
Sync retries reuse verified staging. Hash verification reads the staged tree, but
avoids another network fetch; no repository credentials are needed for execution
of an already synced request. This does not make the GitLab UI available during
an outage or authorize offline execution automatically.

Sync receipts, execution records and private staged trees live under the existing
controller run-state directory. Preserve them across recreation and apply a
site retention policy only after resolving related executions. A snapshot binds
repository bytes, not external services, runtime packages, credential contents
or the live results of dynamic inventory. Inventory resolution is executable
Ansible content and belongs inside the trusted execution boundary.

## Rolling changes across 100+ systems

Start with a reviewed canary inventory/environment, verify service health, then
release the wider environment. One node needs connectivity to every target in its
job. A pool chooses a node; it does not automatically partition inventory across
network zones. Use separate reviewed jobs/environments for different reachability
zones, and protect overlapping targets from concurrent changes.

For a play whose targets share the required reachability, choose a deliberate
batch policy, for example:

```yaml
- name: Apply and verify a rolling change
  hosts: deployment
  serial: [1, 5, "10%"]
  max_fail_percentage: 0
  tasks:
    # Add your change and an actual service health check here.
    - name: Check connectivity before changes
      ansible.builtin.ping:
```

This example starts with one host, then five, then ten percent per batch. With
`max_fail_percentage: 0`, a failed host stops progression; do not defeat that with
`ignore_errors`. Ansible `serial` controls host batches; mesh admission controls
concurrent jobs per node; `forks` controls task concurrency. Tune them against
measured node CPU/memory and target capacity. Higher concurrency is not always
faster or appropriate. Rollback is a separately reviewed recovery action.
See [Ansible execution strategies](https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_strategies.html)
and [failure thresholds](https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_error_handling.html#setting-a-maximum-failure-percentage).

## Reports and recovery

`reports/summary.json` and `summary.html` include allowlisted provenance, controller
status, operation/transfer exit codes and, when present, final Ansible recap totals.
A known playbook success plus artifact-transfer failure remains a failed CI job;
`submit-ambiguous` and `results-incomplete` remain unresolved, never success.
JUnit still reports one aggregate operation check, with distinct sync/deployment
suite names. A sync success does not claim that targets were contacted.

Recap host counts refer to inventory names, not deduplicated machines, and are not
billing or license metrics. Missing recap data is reported as unavailable. Reports
do not copy task result objects, raw stdout, host names or variables. Commit subjects
are displayed with HTML escaping; keep sensitive content out of commit messages.
Raw execution artifacts remain restricted to Maintainers and can contain secrets
if a playbook logs them. Review them before sharing. CI cancellation before report
creation can leave no report; absence is never proof of completion.
