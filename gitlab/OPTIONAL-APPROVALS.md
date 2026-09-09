# Optional licensed approval policies

Skip this page when using **GitLab Community Edition**. The supported CE
workflow is in the [Maintainer guide](MAINTAINER-README.md).

Native protected environments require GitLab Premium/Ultimate. Provision the
policy before releasing a deployment:

```bash
# Group IDs from your GitLab; share the project with both groups first.
PROTECTED_DEPLOY_GROUP_ID=123 PROTECTED_APPROVER_GROUP_ID=456 \
REQUIRED_DEPLOY_APPROVALS=2 \
  gitlab/setup.sh https://gitlab.example.com platform/automation
```

For an already-wired project, run only the policy step with a short-lived
administrator token in the private token file:

```bash
python3 gitlab/protect-environments.py https://gitlab.example.com platform/automation \
  --deploy-group 123 --approver-group 456 --required-approvals 2 \
  --environment prod-mesh --environment prod-direct
```

The script preserves matching policies, refuses drift, and fails on unavailable
or unauthorized APIs. It never silently substitutes CE controls. Group
membership and reviewer independence are site policy; use separate reviewers
and deployers when separation of duties is required. See GitLab's
[protected environments API](https://docs.gitlab.com/api/protected_environments/).
For remote HTTPS installs configure the runner separately as described in the
[walkthrough](MAINTAINER-README.md); the bootstrap's bundled runner URL is for the local HTTP stack.

