# GitLab operator and Maintainer walkthrough

For a screen-by-screen walkthrough, start with [GitLab CE: from first login to Ansible results](STEP-BY-STEP.md).

Use GitLab to store Ansible automation, review changes, and request execution
on this controller. Run host commands from the `ansible-controller` checkout
unless a step explicitly switches to the automation project.

## Community Edition workflow

No Premium subscription is needed. Developers propose Ansible changes;
Maintainers review and merge into protected `main`, then manually release the
chosen deployment job. GitLab displays the result and downloadable artifacts.

![Branch, validation, Maintainer merge and manual deployment](diagrams/workflow.svg)

Keep platform setup with the host administrator. Use a named Maintainer account
for daily reviews and releases; use root only for initial administration.

## 1. Log in

For the running disposable lab, open <http://localhost:8929/users/sign_in>
from the Docker host. From another workstation, use the host's reachable name
or address on port 8929. The configured name `gitlab.lab.local` must resolve
to that host in your browser if GitLab redirects there. `localhost` inside a
container refers to that container, not the Docker host.

Use your named GitLab account for daily work. For initial administration, the
lab uses username `root`; the initial password is the `LAB_ROOT_PASSWORD`
value in `mesh/labs/gitlab/.lab-state/lab.env`. A fresh stack from `gitlab/`
uses `gitlab/.gitlab-state/lab.env` instead. Read that private file locally;
do not paste it into an issue or commit it. A password changed in GitLab
supersedes the initial value in the file.

If GitLab is not installed yet, follow the prerequisite image and first-start
commands at the top of [compose.gitlab.yml](compose.gitlab.yml), then return
here. Do not start a second GitLab on the running lab's port. The provided
HTTP configuration is for the lab; use your site's HTTPS URL and trusted CA
for a shared installation.

## 2. Create an automation project and assign roles

Example project path throughout this guide: `platform/automation`.

1. Ask a group Owner to create the `platform` group, or use an existing group
   where project creation is permitted. Project Maintainer access does not
   automatically grant permission to create projects in every group.
2. Select **New project → Create blank project**. Choose `platform` as the
   namespace, `automation` as the project slug, and **Private** visibility.
3. Leave **Initialize repository with a README** unchecked. Bootstrap seeds
   only empty repositories. If you already have files, use the existing-project
   instructions below.
4. Under **Manage → Members → Invite members**, add the reviewer/release
   operator as **Maintainer**, and playbook authors as **Developer**.
5. Sign out of root and use the named account for reviewing and releasing work.

The host administrator performs the next section using the bootstrap account.
Maintainers subsequently manage the project's reviewed code and releases;
they do not need the bootstrap root token.
See GitLab's [project membership documentation](https://docs.gitlab.com/user/project/members/).

## 3. Connect the project to this controller (host administrator)

The bootstrap needs Bash, Python 3, jq, curl, Git, Docker Compose, a working
controller image, and an existing GitLab instance. Mesh deployment also needs
the working orchestrator, ingresses, and execution node described in
[mesh setup guide](README.md#mesh-setup).
Installing GitLab alone does not create a working mesh.

Create a short-lived root personal access token with `api` scope using the
root account's profile/access-token page. Store it with this Bash prompt so
the value is not embedded in command history:

```bash
umask 077
mkdir -p gitlab/.gitlab-state/ctl-secrets
chmod 700 gitlab/.gitlab-state gitlab/.gitlab-state/ctl-secrets
read -r -s -p 'Bootstrap GitLab PAT: ' gitlab_bootstrap_pat
printf '\n'
printf '%s\n' "$gitlab_bootstrap_pat" > gitlab/.gitlab-state/pat
unset gitlab_bootstrap_pat
```

For the **already-running disposable lab**, set the actual network and runner
names before bootstrap (the controller being wired is `ansible-controller`):

```bash
export GITLAB_NETWORK=gitlab-lab_labnet
export DIRECT_NETWORK=gitlab-lab-ctl_directnet
export RUNNER_CONTAINER=gitlab-lab-runner
export GITLAB_HOST=gitlab.lab.local GITLAB_PORT=8929
export CTL_HOST=ctl.prod.local
```

For the **fresh `gitlab/compose.gitlab.yml` stack**, use its names instead:

```bash
export GITLAB_NETWORK=gitlab-prod_labnet
export DIRECT_NETWORK=gitlab-prod_directnet
export RUNNER_CONTAINER=gitlab-prod-runner
export GITLAB_HOST=gitlab.lab.local GITLAB_PORT=8929
export CTL_HOST=ctl.prod.local
```

Use one of those configurations, then run:

```bash
gitlab/setup.sh http://localhost:8929 platform/automation
```

The URL argument is how the **host** reaches GitLab's API. `GITLAB_HOST` and
`GITLAB_PORT` configure the runner's internal HTTP URL; the environment map's
`gitlab_url` is how the **controller** fetches the repository. `CTL_HOST` is
how CI job containers reach the controller. These addresses must resolve from
their respective networks.

Setup seeds the project, protects `main` and `v*`, requires successful
pipelines for merge, creates fetch credentials and a restricted CI SSH key,
wires the controller, and registers the validation/deployment runner pair.
It also creates an API trigger token; see the approval caveat below.

Before releasing a job, inspect `gitlab/.gitlab-state/environments.yml`:

- `allowed_projects` must include `platform/automation` in each intended environment.
- `gitlab_url` must be reachable from the controller.
- `inventory` is a path within the fetched automation project.
- `ssh_key` is a path in the executing runtime, not a GitLab variable value.
- For `prod-mesh`, `node` must match your enrolled mesh node.

Setup preserves an existing map. An earlier `root/mesh-automation` map will
not automatically become a `platform/automation` map. It also reuses local
token files and fixed runner names: this bootstrap is **not a multi-project
onboarding loop**. For additional projects, provision project-authorized fetch
tokens, runner assignments, scoped CI variables and controller allowlists
deliberately; do not rerun it against a different project and assume access
was transferred.

The defaults use `ansible-controller:e2e` for job images. To choose different
images, set `VALIDATE_IMAGE` and `DEPLOY_IMAGE` before initial bootstrap.
Validation needs Ansible and ansible-lint; deployment needs Git and SSH.
Empty-project seeding writes these choices into the pipeline. Updating a
populated project requires a reviewed change to its image literals.

For an existing remote/HTTPS GitLab, this bundled Docker wiring needs site
adaptation: configure runner registration and checkout trust for that URL,
the controller's `gitlab_url` and CA mount, and a network route from jobs to
`CTL_HOST:22`. The current bootstrap runner registration constructs an HTTP
URL; changing only the first setup argument does not configure HTTPS runners.
See [private-CA fetch guidance](README.md#private-ca-project-fetch).

After successful connection verification, revoke the bootstrap PAT:

```bash
REVOKE_BOOTSTRAP=1 gitlab/setup.sh http://localhost:8929 platform/automation
```

This is a separate revocation-only invocation. Keep the generated deployment
credentials available to their runtimes; do not revoke them with the PAT.
GitLab documents [personal access tokens](https://docs.gitlab.com/user/profile/personal_access_tokens/).

## 4. Verify the project before its first deployment

In **Settings → Repository → Branch rules** (or **Protected branches**):
`main` must allow merge by Maintainers, allow push by no one, and disallow
force push. The `v*` tag rule should allow creation by Maintainers.
In **Settings → Merge requests**, verify **Pipelines must succeed**.
Setup fails on mismatched existing protection; reconcile the intended policy
instead of deleting protection to get past the error.

In **Settings → CI/CD → Runners**, verify the `mesh-validate` runner is online
and the `mesh-deploy` runner is online and protected. Both are project-locked
and reject untagged jobs. In **Variables**, verify these entries:

| Variable | Type / scope | Purpose |
|---|---|---|
| `CTL_SSH_KEY` | Protected File, `prod-*` by default | CI-to-controller restricted private key |
| `CTL_KNOWN_HOSTS` | Protected File, same scope | Pinned controller SSH host key |
| `CTL_HOST` | Protected variable, same scope | Controller network name |

File variables give jobs temporary file paths. Do not echo their contents or
enable shell tracing around credentials. Multiline keys are not made safe by
assuming GitLab masking will hide them. No mesh TLS/work-signing keys or
Vault passwords belong in these variables. The runner manager holds the Docker
socket; job containers receive neither that socket nor mesh submission mounts.

For a populated repository, add the files needed from
[`project-seed`](../mesh/labs/gitlab/project-seed/) on a feature branch,
preserving your existing automation. Change **all** `lab-direct` / `lab-mesh`
references in its `.gitlab-ci.yml` to `prod-direct` / `prod-mesh`, including
environment names and `ctl-run --env` arguments. Set the two image names,
inventory paths and playbooks for your project, validate the merged CI YAML
in GitLab's pipeline editor, and review the change before merging.

## 5. Change Ansible automation and request review

Clone the seeded automation project into a separate directory. Use the HTTP/S
clone URL shown by GitLab; the bundled compose file does not publish GitLab
SSH, and host port 2222 belongs to the Ansible controller. If prompted for a
Git password, use your named account's repository-scoped token; do not put it
in the clone URL.

```bash
git clone http://localhost:8929/platform/automation.git
cd automation
git switch -c change/site-message
# Edit playbooks/site.yml, roles, inventory, or group_vars as needed.
git add playbooks/site.yml
git commit -m 'Update the site automation'
git push -u origin change/site-message
```

Create a merge request targeting `main` and assign a Maintainer as reviewer.
State the intended hosts, change, expected result, and recovery plan. The
validation job runs syntax checks and ansible-lint. Extend its playbook list
when adding new entry points. Review inventory, roles, collections and CI
changes together: reviewed playbooks execute with real target privileges.

As reviewer, open **Merge requests**, inspect the diff and validation result,
request corrections or select **Approve**, then **Merge** when ready.
Push corrections to the same feature branch; GitLab updates the MR and runs
validation again. In CE, approval is recorded but is not a required approval
rule. Maintainer-only merge and successful pipelines are the enforced merge
controls. See [GitLab approvals](https://docs.gitlab.com/user/project/merge_requests/approvals/).

## 6. Release the reviewed commit

1. Open **Build → Pipelines**, then the pipeline for the merged `main` commit.
2. Confirm its commit SHA and validation result.
3. Open the desired manual job: **deploy-direct** for standalone execution or
   **deploy-mesh** for mesh execution. Select **Run/Play** for that job only.
4. Watch its job log. The job sends the actual checked-out commit SHA to
   `ctl-run`; the controller fetches that commit and uses its own environment
   map to select inventory, execution mode and credentials.
5. Check the job result and target state. The seed's `site.yml` writes commit
   provenance to `/home/ansible/lab-deployed.txt` on the demo target.

Both deployment jobs are offered on `main`; an unplayed blocking manual job
can leave the overall pipeline blocked even when the deployment you selected
succeeded. Do not run the other environment just to turn the pipeline green.
For a project using one mode, remove the unused deployment job through review.

**Approval surface:** `scheduled-check`, `api-deploy`, and `tag-deploy` are
manual too. `DEPLOY_CONFIRM=yes` only creates an API deployment candidate; an
allowed human still releases it. Remove unused schedules and revoke unused
trigger tokens under **Settings → CI/CD → Pipeline trigger tokens**. Maintainers
who can change project policy or merge pipeline code remain trusted administrators
of this flow. Older seeded projects must adopt the updated pipeline through review.

CE records merge-request approvals but does not enforce reviewer counts.
Protected branch permissions and manual job release provide this guide's gates.
If your organization later adopts a licensed GitLab edition, see
[optional approval policies](OPTIONAL-APPROVALS.md).

## 7. Results, recovery and future updates

A completed playbook's exit code becomes the deployment job result. A failed
or timed-out job alone does not prove the playbook never ran. Keep the mesh
UUID from its log and inspect the controller's lifecycle state before retrying.

| Observed result | Next action |
|---|---|
| Validation fails | Correct the branch and rerun validation; no deployment was authorized by that validation job |
| Admission refuses a slot | Verify no submission occurred, then retry when capacity is available |
| Wait deadline / `results-incomplete` | Collect the original job; do not submit another execution |
| Completed playbook fails | Inspect its output and target changes; review a correction before another deployment |
| Completed job is retried | Same pipeline/environment/project/playbook returns the original result and exports it again; no execution |

For recovery, open the manual **collect** job on `main`, set `JOB_ID` to the
original mesh UUID in the manual job's variable form, and run it. This calls
`ctl-run --collect` through the same restricted SSH connection. Unknown or
ambiguous submission states need administrator reconciliation on the controller.

CI displays console output. Controller audit records are under
`/var/lib/gitlab-runs/records/` and streamed mesh logs under
`/var/lib/gitlab-runs/logs/`. Mesh lifecycle metadata lives under
`/var/lib/mesh/jobs/<uuid>/meta.json`; mesh runner artifacts default to
`/var/log/ansible/runner/<uuid>/` inside the controller, exposed as
`logs/runner/<uuid>/` in the host checkout by the standard log mount. Open the
deployment job's **Browse artifacts** and look under `mesh-artifacts/`. Results
include `ctl-run.json`, available console output, and the mesh UUID's `meta.json`,
stdout, rc/status and JSON events. Artifact download is restricted to Maintainers
and expires after seven days. Staging trees and credentials are not exported.

Request claims in `/var/lib/gitlab-runs/requests/` must persist alongside their
records: pruning them removes retry protection. Retry the original pipeline job
to recover a transfer failure; starting a new pipeline intentionally creates a
new execution request. Old runs predating this journal are not protected retroactively.

For the next automation update, repeat branch → validation → MR → merge →
manual deployment. A rollback is also a reviewed change: revert the relevant
commit on a branch, validate it, merge it and deliberately deploy it. Reverting
code does not necessarily undo target changes, so review the recovery playbook.

Connection changes have a separate operator step: update the environment map
and runtime trust/credentials for new targets or a new GitLab URL, then verify
connectivity before release. Rotate the CI SSH key and its authorized-key entry
together, pin a changed controller host key only after verifying it through the
host, and update protected file variables. Never disable host-key checking to
make a failed connection succeed.

Do not commit `.gitlab-state/`, `.lab-state/`, private keys, tokens or Vault
passwords into the automation repository. Encrypted Vault data can be reviewed
in Git; its password must be provisioned to the executing runtime separately.

## Save deployment credentials and release a version

Your GitLab account identifies who reviews and releases automation. The target
account (for example, `svc_ansible`) identifies Ansible to the managed servers.
A release tag selects a code version; it does not contain a password or select
credentials by itself. The controller environment map selects the inventory and
execution destination. Runner tags such as `mesh-deploy` only route jobs.

### One-time target credential setup

The host administrator creates or selects the target automation account and
assigns the permissions the playbooks require. Prefer a dedicated account. For
SSH-key authentication, provision its private key to the executing runtime and
configure the environment's `ssh_key`; do not put it in the automation repository.
For username/password authentication, use the following Vault workflow.

From a trusted workstation with Ansible installed, inside the **automation
project**, create a Vault file for an existing inventory group. This example
assumes the selected inventory contains a `[deployment]` group; substitute your
actual group name. Keep `group_vars` beside that inventory, in a directory the
environment map can select as a whole:

```bash
mkdir -p inventory/production/group_vars/deployment
git mv inventory/hosts.ini inventory/production/hosts.ini   # if it is still a bare file
ansible-vault create inventory/production/group_vars/deployment/vault.yml
```

Then set that environment's `inventory: inventory/production` — the **directory**,
not a file inside it. The distinction only matters in mesh mode, and it fails
silently: `mesh-run` copies a file inventory into the payload as that single file,
so sibling `group_vars` stay behind in the staged project copy, where Ansible
looks for neither inventory-adjacent nor playbook-adjacent variables. The play
then connects with no username or password rather than reporting a missing
credential. A directory inventory is staged whole, so the encrypted variables
travel with it. Standalone execution runs `ansible-playbook` in the fetched tree,
where both layouts resolve — which is why a file selection can appear correct
until the same project is dispatched through the mesh.

The command prompts locally for a new Vault password and opens an editor. Enter
these variables there, replacing the example values with the target credentials:

```yaml
ansible_user: svc_ansible
ansible_password: "REPLACE_WITH_TARGET_PASSWORD"
# Only when privilege escalation requires a password:
ansible_become_password: "REPLACE_WITH_SUDO_PASSWORD"
```

Save and close the editor. Commit the encrypted `vault.yml`, never a plaintext
copy or the Vault password. Enable `become: true` only on plays/tasks that need
privilege escalation; supplying its password alone does not enable it. Ensure
the target permits the selected authentication method. The bundled Linux image
includes `sshpass`; custom execution images must support password authentication.

Provision the **Vault decryption password** separately:

- **Standalone controller:** the administrator supplies a private file at
  `/configs/.vault_pass` (normally host `configs/.vault_pass` through the configs
  mount). At startup, the controller entrypoint copies it to the private
  `/home/ansible/.vault_pass`; `ctl-run` restores that password-file setting after
  sudo. Arrange the startup/restart through normal host operations.
- **Mesh:** provision a private, read-only password file on each eligible execution
  node, readable by its Ansible execution user. In the automation project's
  `ansible.cfg`, set `vault_password_file` under `[defaults]` to that node-local
  absolute path, for example `/run/secrets/ansible_vault_password`. Merge this
  setting into the existing config. Provision the mount/file before running;
  merely naming the path does not create it. The mesh node does not run the
  controller entrypoint, and `ssh_key` and `galaxy_dir` do not transport Vault
  passwords. A project used in both modes needs config paths valid in both
  runtimes, or separately reviewed configurations.

Keep the password outside the Git checkout when possible; restrict host file
permissions and grant runtime read access deliberately. Neither the GitLab login
password nor `CTL_SSH_KEY` decrypts Vault data. Do not put target passwords in
manual-job variables or expect `--ask-pass`/`--ask-vault-pass` to prompt in CI.
The current integration has no secure per-run password-entry form.

Vault protects stored data; reviewed playbooks can decrypt it at execution time.
Use `no_log: true` on tasks that handle secrets and avoid debugging credential
variables. See [Ansible Vault](https://docs.ansible.com/projects/ansible/latest/vault_guide/vault.html)
and [using encrypted content](https://docs.ansible.com/projects/ansible/latest/vault_guide/vault_using_encrypted_content.html).

### Validate without production credentials

The seed's validation job currently loads `inventory/lab.ini`. Adding encrypted
variables to that inventory can make syntax checking or linting request Vault
material. Before merging, adapt validation to use a separate nonsecret fixture
inventory and dummy variables as needed by the playbooks. Check both syntax
checking and linting in the actual validation image. Do not give the validation
runner the production Vault password. A host operator should separately verify
real target authentication with a reviewed, non-mutating connectivity playbook.
The supplied template does not configure this credential-specific validation
split automatically.

### Review, tag, run and inspect

1. Push the encrypted inventory and playbook changes on a branch, pass validation,
   and have a Maintainer review and merge into protected `main`.
2. For a release, verify **Settings → Repository → Protected tags** has `v*`
   restricted to creation by Maintainers. Also retain the protected deployment
   runner and scoped variables described above. Protecting `main` alone does not
   protect tags.
3. In **Code → Tags → New tag**, create a tag such as `v1.0.0` on the exact reviewed
   commit. Tag permission does not itself prove that a commit passed review;
   check the selected commit before creating the tag.
4. Open the tag pipeline in **Build → Pipelines**. After validation succeeds,
   manually release `tag-deploy`. The seed maps it to `lab-mesh`; integrated
   bootstrap maps it to `prod-mesh`. Check the actual project's environment.
5. Open the job trace, then **Browse artifacts → mesh-artifacts/** for results.
   The updated helper preserves the playbook result and retrieves artifacts.

Alternatively, manually release `deploy-mesh` or `deploy-direct` from the reviewed
`main` pipeline without creating a tag. Deploy through one chosen route: a tag
pipeline and a main pipeline are separate requests and can both execute, even
when they reference the same commit. A fresh release does not require saving
credentials again. Rotate the target password using `ansible-vault edit` and a
reviewed credential update; coordinate target-side rotation with deployment.

This workflow uses Community Edition protected refs and manual jobs; it does
not enforce a separate multi-person deployment approval count.

### Existing lab upgrade prerequisite

Updating this controller repository does not update a populated GitLab project.
Before relying on artifact downloads and durable retries, apply the current
`.gitlab-ci.yml` and `scripts/ctl-ci.sh` together through a reviewed project change,
verify the controller runs the matching implementation, and check protected tag
rules. Existing jobs do not acquire artifacts or retry protection retroactively.
Credential files, node mounts and target accounts are separate administrator
setup; these documentation examples do not provision them.

## Troubleshooting

| Symptom | Check |
|---|---|
| Browser cannot connect | GitLab container health, port 8929, host firewall and browser DNS |
| Job stays pending | Runner online, matching tag, protected-ref status, job image availability |
| Missing SSH key variable | Job environment matches `prod-*` and ref is protected |
| SSH host verification fails | `CTL_HOST` and verified pinned key; do not bypass checking |
| Project not allowed / fetch denied | Controller map's project path, GitLab URL, deploy-token authorization and CA trust |
| Mesh node unavailable | Node enrollment, correct node name, ingress connectivity on 27199/27200 |
| No artifacts button | Check job trace for export/upload failure, Maintainer access and seven-day expiry; retain controller evidence |

For tested behavior and limits, see [VERIFICATION.md](VERIFICATION.md).
