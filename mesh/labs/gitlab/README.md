# GitLab Community Edition lab

Use this disposable lab to try Ansible changes through GitLab CE: create a
branch, validate, review, merge, manually deploy, and download results. No
Premium subscription is required.

For an existing installation, use the [Maintainer guide](../../../gitlab/MAINTAINER-README.md).
For reproducible isolated testing, use the [audit suite](../../../gitlab/tests/README.md).

## How it connects

![GitLab jobs reach the controller over SSH](../../../gitlab/diagrams/components.svg)

The Runner polls GitLab and starts jobs. Deployment jobs use a restricted SSH
key to call `ctl-run` on `gitlab-lab-ctl`. That controller fetches the exact
commit and dispatches through the existing mesh ingress sockets. Execution
nodes connect outward to the ingress and run the playbook against their targets.

CI jobs have no mesh socket/state volumes, signing keys or target credentials.
The controller extension holds the mesh mounts. The Runner manager holds the
Docker socket for its executor; it does not pass that socket to job containers.

## Start the disposable lab

Run from the repository root on a host with Docker Engine, Compose v2, at least
6 GiB available RAM, 10 GB free disk and host port 8929 available.

```bash
mesh/labs/gitlab/lab-up.sh
```

To use a local controller image, pass its tag as the first argument. The script
creates the repository's `mesh-e2e` stack, GitLab/Runner and a controller extension.
It therefore owns those disposable resources: do not run it against a mesh-e2e
stack whose state you need to preserve.

Open <http://localhost:8929>. The project is
[root/mesh-automation](http://localhost:8929/root/mesh-automation).
Bootstrap creates `root` and the Developer account `dev1`; it creates no named
Maintainer, so on a fresh lab `root` is the only account that may merge to
protected `main`. Initial passwords are recorded in `.lab-state/lab.env`;
inspect that private file locally. A password changed in GitLab supersedes the
file's initial value.

| Item | Lab value |
|---|---|
| Browser URL on the host | `http://localhost:8929` |
| GitLab name within the job network | `gitlab.lab.local:8929` |
| Controller name within the job network | `ctl.lab.local:22` |
| Controller container | `gitlab-lab-ctl` |
| Environments | `lab-direct`, `lab-mesh` |
| Private bootstrap state | `mesh/labs/gitlab/.lab-state/` |

Do not start another GitLab on the same port. HTTP and the container FIPS-flag
workaround are disposable-lab settings, not a claim of production TLS or FIPS
compliance. For shared deployment use the [integration setup](../../../gitlab/README.md).

## Make and release an Ansible change

1. Log in as a Developer and create a branch from `main`.
2. Update `playbooks/site.yml`, inventory or roles; open a merge request.
3. Wait for the `validate` job to pass syntax and lint checks.
4. Review and merge. Protected `main` accepts merges from Maintainers only and
   `dev1` cannot merge, so in a fresh disposable lab the administrator account
   `root` reviews and merges. To rehearse the production separation instead,
   create a named user as root under **Admin → Users → New user** (Regular, not
   Administrator), add it to `root/mesh-automation` under **Manage → Members →
   Invite members** with role **Maintainer**, then review and merge as that
   user. Shared installations do this from the start; see
   [assign roles](../../../gitlab/MAINTAINER-README.md#2-create-an-automation-project-and-assign-roles).
5. Open **Build → Pipelines** for the merged commit. Manually run `deploy-mesh`
   or `deploy-direct`, according to the target environment you intend to change.
6. Inspect the job trace and **Browse artifacts → mesh-artifacts/**. The seed
   playbook writes the deployed commit to `/home/ansible/lab-deployed.txt` on its target.

Both deployment modes are offered. An unused blocking manual job can leave the
pipeline blocked; do not deploy an unwanted environment just to turn it green.
For a project using one mode, remove the unused job through a reviewed change.

The CE gates are protected `main`, Maintainer-only merge, successful validation,
protected deployment runners/variables, and manual release. MR approvals are
recorded but CE does not enforce approval counts. Schedules, triggers and release
tags also require a manual release in the current template.

## Results and retries

A completed playbook's exit code is preserved. GitLab uploads run metadata,
console output when available, and mesh result files with Maintainer download
access and a seven-day expiry. Execution success with failed artifact transfer
makes the job fail visibly; retrying the same job attempts export again.

Retrying the same pipeline/environment/project/playbook returns its recorded
result without re-execution. A new pipeline is a new deliberate execution.
Keep the controller's request claims and records; deleting them removes this
protection. Older projects must adopt the current pipeline and helper through
review, because bootstrap does not overwrite a populated repository.

## Recover incomplete results

Cancellation or a wait deadline does not prove the remote play stopped.
Keep the mesh UUID from the job trace. Open the manual `collect` job, set
`JOB_ID` to that UUID, and run it. The job calls `ctl-run --collect` over SSH
and uploads the original result files.

`submit-ambiguous` is different. The record carries no unit id, so the CI
`collect` job has nothing to re-attach to, and `ctl-run` refuses every later
deployment while the record is non-final. Only the host operator can resolve
it, on the controller container that holds the mesh volumes:

```bash
docker exec gitlab-lab-ctl cat /var/lib/mesh/jobs/<uuid>/meta.json
docker exec gitlab-lab-ctl receptorctl --socket /run/receptor/receptor.sock   work list
docker exec gitlab-lab-ctl receptorctl --socket /run/receptor/receptor-b.sock work list
```

Correlate that record with a unit on either ingress, then follow
[Resolve an ambiguous submission](../../RUNBOOK.md#resolve-an-ambiguous-submission)
for the three outcomes and the exact record transition, substituting
`gitlab-lab-ctl` for `ansible-controller` and
`docker exec gitlab-lab-ctl /usr/local/mesh/bin/mesh-run --collect <uuid>` for
`make mesh-collect` (this lab has no `ansible-controller` container). An adopted
unit can equally be collected by the manual `collect` job with `JOB_ID` set to
the same UUID. That job accepts `JOB_ID` only; the seed project's legacy
`RESOLVE_AMBIGUOUS` variable is not its recovery interface. Do not clear a slot
hold or mark an unknown job failed merely because one ingress no longer lists it.

## Credentials and retention

Keep `.lab-state/`, target keys and mesh PKI out of automation repositories.
Rotate user passwords in GitLab and update your private operator records.
Revoke obsolete runner and trigger tokens in GitLab. Recreating a state file
does not change an existing account's password or server-side token.

Preserve unresolved mesh records and `/var/lib/gitlab-runs/requests/` with their
run records. GitLab artifact expiry does not authorize deleting controller
claims. The [architecture guide](../../../gitlab/ARCHITECTURE.md) explains the
credential and storage boundaries.

## Remove the disposable lab

These commands delete the lab containers and volumes, including its GitLab
projects and mesh state. Export evidence you need before running them.

```bash
mesh/labs/gitlab/lab-down.sh
```

For a full reset that also removes local bootstrap credentials and disposable
PKI, use `mesh/labs/gitlab/lab-down.sh --purge`. Retained state from a deleted
GitLab database must be reconciled before another bootstrap.
