# Support and deployment assistance

Ansible Controller is available under [Apache-2.0](LICENSE). The community
controller and mesh have no host limit or purchase requirement. Sponsorship,
paid services, and contributions are optional.

## Learn more

For deployment assistance or paid support enquiries, contact the maintainer at
[tsuliman@linuxvaults.com](mailto:tsuliman@linuxvaults.com?subject=Ansible%20Controller%20support%20enquiry).

Possible scopes include initial controller setup, mesh deployment planning,
GitLab integration, upgrades, and troubleshooting. Describe the work you need,
your approximate fleet size, deployment mode, and timeline. Do not send private
keys, passwords, tokens, or confidential inventories.

Availability, scope, fees, and any response commitments must be agreed before
work starts. This project does not currently offer a published enterprise feature
tier, a standard SLA, or an enterprise license that you must buy to continue.
Sponsorship alone does not purchase a support contract or guarantee a response.

## Sponsor

- [GitHub Sponsors](https://github.com/sponsors/allamiro)
- [Buy Me a Coffee](https://buymeacoffee.com/pcileky2q)

Financial support helps maintain the project. Bug reports, documentation, and
code contributions are also welcome, without a contribution quota.

## Continue free

Keep using the project normally, including for fleets larger than 100 systems.
There is no activation step, payment check, or license server.

Fleet size is only useful context for a support enquiry. For that conversation,
count each distinct managed operating-system instance once: multiple inventory
aliases for the same instance are one system; separate VMs are separate systems.
Controller and execution nodes count only when they are themselves managed
targets. For ephemeral environments, describe typical and peak fleet sizes.
This is a scoping convention, not usage metering or a pricing rule. The software
does not collect or transmit these counts.

## Terminal notice

New images show the optional links once per interactive Bash session, including
`make shell`, `docker exec -it ansible-controller bash`, and interactive SSH
logins. Nested shells inherit the notice marker. The notice immediately returns
control; it never reads input or launches a browser. Follow a link yourself if
you want to learn more or sponsor the project.

To display it on demand from a terminal:

```bash
make support                    # on the host, from the repository checkout
controller-support              # inside a new controller image
```

To disable it for the current shell and its children:

```bash
export ANSIBLE_CONTROLLER_SUPPORT_NOTICE=0
```

For Docker-exec shells, set that variable in the container environment (for
example in Compose), or pass `-e ANSIBLE_CONTROLLER_SUPPORT_NOTICE=0` to
`docker exec`. For SSH logins, put the export in the controller user's
`~/.ssh/environment` only if your site's SSH policy permits it; otherwise create
`~/.hushlogin` as described below.

The notice requires terminal stdin, stdout, and stderr. It stays silent for
noninteractive sessions and when a standard CI indicator is set (`CI`,
`GITHUB_ACTIONS`, `GITLAB_CI`, `TF_BUILD`, `JENKINS_URL`, `BUILDKITE`, `CIRCLECI`,
or `TEAMCITY_VERSION`). It is not called by the entrypoint, playbook commands,
GitLab execution wrappers, or mesh workers, and never writes to stdout.

## Community help

Use [GitHub issues](https://github.com/allamiro/ansible-controller/issues/new/choose)
for reproducible bugs and feature requests. Community help is provided as time
permits. The project license and the licenses of bundled dependencies remain in
effect regardless of sponsorship or any separately agreed services.
