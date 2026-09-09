# Ansible automation project template

Copy this directory into a new GitLab CE project. It provides a non-mutating
Linux connectivity playbook, protected manual deployment, result artifacts,
and a JUnit summary displayed inside GitLab. No additional results server is
needed. This is a starting project, not automatic controller provisioning.

## Create a project from this template

1. Create an empty private project in GitLab. Assign authors Developer access
   and release operators Maintainer access. Leave README initialization off.
2. From your controller checkout, copy this directory, including hidden files,
   into a new empty directory outside that checkout:

   ```bash
   mkdir ../my-automation
   cp -a gitlab/project-template/. ../my-automation/
   cd ../my-automation
   git init -b main
   ```

3. Replace `192.0.2.10` in `inventory/production/hosts.ini` with your target and select its
   automation account. Start with the supplied connectivity play before adding
   changing tasks to `playbooks/site.yml`.
4. Replace the pipeline image with your tested, runner-accessible controller
   image. It needs Bash, Git, SSH, Python 3, Ansible and ansible-lint. The shipped
   `registry.example.com/ansible-controller:REPLACE-ME` resolves nowhere on
   purpose, so a forgotten replacement fails immediately instead of running
   something unintended.
5. Have the host administrator connect the exact project to the controller as
   described below. Establish the initial `main` commit before enforcing the
   no-direct-push rule; after bootstrap all changes go through merge requests.
6. Review the files and push using your actual project's clone URL:

   ```bash
   git add .
   git commit -m "Initialize Ansible automation project"
   git remote add origin https://gitlab.example.com/platform/my-automation.git
   git push -u origin main
   ```

   Replace the URL. Authenticate through your credential manager, never a token
   embedded in the URL. No deployment starts automatically.

## Administrator connection checklist

For this template, the controller environment `prod-direct` must allow the exact
new project path and select the inventory **directory** `inventory/production`
(not a file inside it — see the Vault section below). Provision a project-authorized
read-only fetch token on the controller. Provision target SSH trust and either
its automation SSH key or the Vault credentials described below.

Register/assign the validation runner (`mesh-validate`) and protected deployment
runner (`mesh-deploy`). Configure protected File variables `CTL_SSH_KEY` and
`CTL_KNOWN_HOSTS`, plus `CTL_HOST`, scoped to `prod-direct`. Protect `main` so no
one pushes directly and only Maintainers merge. Require successful validation.
Protect `v*` so only Maintainers create release tags. Do not grant this execution
environment to untrusted playbook authors: reviewed code executes with its
provisioned credentials.

For mesh, replace **both** `prod-direct` literals in `.gitlab-ci.yml` with your
mesh environment. The administrator must configure that environment's mode,
node/pool/zone and inventory, and provision runtime secrets on eligible nodes.
A changed CI environment name alone does not connect the mesh.

The existing `gitlab/setup.sh` bootstrap in the controller repository seeds only
empty projects and uses its lab-oriented seed. To use this template, initialize
the repository with these files first, then provision its connection deliberately.
Existing fixed runner/token state is not reusable as an automatic multi-project
registration loop. Follow the controller's `gitlab/MAINTAINER-README.md` connection
procedure and reconcile existing configuration rather than overwriting it.

## Password credentials with Ansible Vault

For SSH keys, keep the private key on the controller/runtime as configured by the
administrator. To use a password, create encrypted variables locally:

```bash
mkdir -p inventory/production/group_vars/deployment
ansible-vault create inventory/production/group_vars/deployment/vault.yml
```

Keep the environment map pointed at the directory `inventory/production`. In mesh
mode the distinction decides whether these credentials arrive at all: `mesh-run`
copies a file inventory into the payload as that single file, so sibling
`group_vars` stay behind in the staged project copy, where Ansible looks for
neither inventory-adjacent nor playbook-adjacent variables, and the play then
connects with no username or password instead of reporting a missing credential.
A directory inventory is staged whole. Standalone execution runs in the fetched
tree and resolves both layouts, so a file selection can look correct until the
same project is dispatched through the mesh.

In the Vault editor enter the real `ansible_user`, `ansible_password`, and only
if needed `ansible_become_password`. Commit the encrypted file. The administrator
must separately provision its decryption password on the execution runtime.
See **Save deployment credentials and release a version** in the controller's
`gitlab/MAINTAINER-README.md` for standalone and mesh password-file configuration.
Do not enter passwords in manual GitLab job variables.

Validation uses `inventory/validation/hosts.ini`, a separate directory with no
adjacent `group_vars`, and does not execute the play. Keep production
secrets out of `playbooks/group_vars` and do not add static production Vault
loads to validation. If new roles require variables at syntax/lint time, provide
nonsecret fixtures and test validation without the production Vault password.

## Review and deploy

1. Create a feature branch, edit playbooks/inventory, push and open a merge request.
2. Wait for `validate`; a Maintainer reviews and merges into protected `main`.
3. Open the new pipeline and manually release **deploy**. Leave password variables
   empty. Confirm the environment and commit before clicking Run.
4. Alternatively, create a protected `v*` tag on that reviewed commit and release
   its manual **deploy** job. Choose one route: tag and main pipelines can both
   execute the same commit as separate requests.

This starter accepts push and merge-request pipelines. Schedules, API triggers
and web-created pipelines are deliberately not configured. Add those routes
through a reviewed change to `workflow` and job rules while retaining manual
release and protected-ref restrictions. GitLab runner tags select a runner;
Git release tags select a commit.

## View results inside GitLab

Open **Build → Pipelines → your pipeline → Tests** after deployment finishes.
The `Ansible deployment` suite contains one case, **Deployment and result
transfer**. A nonzero deployment/transfer exit code produces a failed case and
keeps the CI job failed. This does not count individual Ansible tasks or hosts.
GitLab supports [JUnit reports in its Free tier](https://docs.gitlab.com/ci/testing/unit_test_reports/).

Open the job trace for Ansible output. Under **Browse artifacts**, download:

- `reports/deployment.xml`: the same aggregate result used by GitLab's Tests tab.
- `reports/summary.html`: a standalone summary you can open locally; in-browser
  artifact preview depends on GitLab configuration.
- `mesh-artifacts/`: controller records and available execution output.

The generated summaries contain only a fixed status message and exit code; they
do not copy raw task output or decrypted variables. Review playbook logging for
secret exposure before sharing execution artifacts. The artifact archive is
restricted to Maintainers, but do not assume that this hides the Tests-tab status
from everyone who can view the pipeline. Default retention is seven days subject
to GitLab's keep-latest settings.

JUnit reports do not control job status themselves. `scripts/deploy.sh` preserves
the original deployment exit code and treats report-generation failure as an
error after an otherwise successful deployment. Abrupt cancellation, runner loss,
or setup failure before the script runs can leave no report; no report is not
proof of success. This is a post-run summary, not a live host-event stream.

## Recovery and supported scope

This uses the current controller's durable request journal via `scripts/ctl-ci.sh`.
Retry of the same completed pipeline request reuses its result; a new pipeline
is a new execution. The controller must run the matching artifact/journal code.
For incomplete or ambiguous mesh work, use the controller's documented collection
and host reconciliation procedures before dispatching again. This minimal template
has no collection UI job; the full lab seed includes one.

The default play is Linux SSH connectivity. Windows/WinRM, multiple environments,
HA and external credential brokers need explicit configuration and verification.
No target accounts, secrets or runtime mounts are created by copying this project.
AWX and Semaphore are alternative automation UIs, not preconfigured viewers for
this template's existing mesh results. Begin with the GitLab Tests tab and artifacts.
