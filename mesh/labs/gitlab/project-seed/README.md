# Ansible automation project

This project stores Ansible playbooks and their GitLab Community Edition pipeline.
Changes are reviewed before a Maintainer manually releases execution on the
controller or mesh. No Premium subscription is needed.

## Project files

| Path | Purpose |
|---|---|
| `playbooks/site.yml` | Example configuration change that records the deployed commit on the target |
| `playbooks/ping.yml` | Connectivity check |
| `inventory/` | Project inventories selected by the controller's environment mapping |
| `.gitlab-ci.yml` | Validation, manual deployment and collection jobs |
| `scripts/ctl-ci.sh` | Restricted SSH invocation and result download |

Other scripts in `scripts/` support historical lab experiments. The current
pipeline uses `ctl-ci.sh`; it does not give jobs direct mesh socket access.

## Change, review and deploy

1. Create a branch from `main` and edit the relevant playbook, role or inventory.
2. Push the branch and open a merge request.
3. Wait for `validate` to pass, then ask a Maintainer to review and merge.
4. Open **Build → Pipelines** for the merged commit.
5. Manually run `deploy-mesh` or `deploy-direct` for the intended environment.
6. Read the job trace and open **Browse artifacts → mesh-artifacts/**.

Select only the deployment mode you intend to run. An unplayed blocking manual
job can leave the overall pipeline blocked even after the selected job succeeds.
MR approvals are optional in CE; protected-branch permissions and manual release
are the enforced gates. Schedules, API triggers and release tags are manual too.

## Results and recovery

The job preserves a completed playbook's exit code. Artifacts include
`ctl-run.json` and, for mesh runs, `logs/runner/<uuid>/meta.json`, stdout,
rc/status and available JSON events. Downloads require Maintainer access and
expire after seven days by default. Do not print secrets in playbook output.

Retrying the same pipeline request returns the original result without another
execution. A new pipeline intentionally creates a new request. If execution
succeeds but export fails, the job fails with an artifact-transfer message;
Retry attempts the download again.

For `results-incomplete`, use the manual `collect` job with `JOB_ID` set to the
original mesh UUID. Cancellation can leave remote work running. Ask the host
operator to reconcile an ambiguous submission before attempting another dispatch.

## First-project configuration

The supplied template uses `lab-*` environments. Host bootstrap for the main
integration rewrites these to `prod-*` when seeding an empty project. The
controller map, CI environment names and protected file-variable scopes must
agree. Ask the host administrator to configure `CTL_HOST`, `CTL_SSH_KEY` and
`CTL_KNOWN_HOSTS`; keep mesh and target credentials on the executing runtime.

For an existing project, update both `.gitlab-ci.yml` and `scripts/ctl-ci.sh`
through a merge request. Bootstrap preserves populated repositories. Include
new playbook entry points in the validation job when adding them.

## Target credentials and release tags

Your GitLab login authorizes project actions; Ansible uses a separately configured
target account. Store target passwords in an Ansible Vault-encrypted inventory
file and provision the decryption password on the controller or execution node.
Do not enter target passwords as manual-job variables. Keep validation on a
nonsecret fixture inventory when production inventory requires Vault.

A Maintainer can create a protected `v*` tag on a reviewed commit, then manually
release `tag-deploy` after validation. The tag selects code; the job environment
selects inventory and runtime credentials. A tag pipeline is a new execution
request even if that commit was already deployed from `main`.

For the complete setup, see **Save deployment credentials and release a version**
in `gitlab/MAINTAINER-README.md` of the controller repository. Provisioning secrets
and protecting tags are administrator steps, not effects of pushing this README.
