# Ansible Controller

A **community open-source Ansible control node** on Ubuntu 26.04, with an OpenSSH
server and a host-mounted configuration. Run playbooks directly against reachable
SSH or Windows/WinRM targets. Available for **linux/amd64 and linux/arm64** on
Docker Hub and at `ghcr.io/allamiro/ansible-controller`.

The standalone controller has **no host limit, purchase requirement, or automatic
support notice**. Sponsorship is voluntary. For targets in isolated networks, use
[Ansible Orchestrator](https://hub.docker.com/r/allamiro1/ansible-orchestrator) with
[Ansible Execution Node](https://hub.docker.com/r/allamiro1/ansible-execution-node).

## Links and tags

- [Source and full guide](https://github.com/allamiro/ansible-controller)
- [Releases](https://github.com/allamiro/ansible-controller/releases) and the Docker Hub **Tags** tab
- [Dockerfile](https://github.com/allamiro/ansible-controller/blob/main/docker/Dockerfile)
- [Issues](https://github.com/allamiro/ansible-controller/issues)
- Maintainer: Tamir Suliman

| Tag | Meaning |
| --- | --- |
| `x.y.z` (for example `0.29.0`) | Versioned release; all three images share the version |
| `x.y`, `x` | Moving minor/major version aliases |
| `latest`, `main` | Most recently published main build |
| `sha-<shortsha>` | Build associated with a source commit |

Use a tested release in production and pin its digest when exact image content
must remain fixed. The example below uses the published `0.29.0` release; select
your required version from **Tags**.

## Included runtime

- `ansible-core`, `ansible-lint`, `ansible.posix` and `community.general`.
- `pywinrm` with NTLM support, plus common controller-side Python dependencies.
- OpenSSH server, Git, sudo and command-line tools.
- Startup installers for declared Galaxy and Python requirements.
- SSH login account `ansible` (UID 1000), with passwordless sudo. The container
  starts as root to initialize services; default `docker exec` commands run as root.

Windows execution also needs the appropriate collections, inventory, credentials
and WinRM trust configuration. Installing Python support alone does not configure
Windows hosts.

## Start with the repository configuration

```bash
git clone https://github.com/allamiro/ansible-controller.git
cd ansible-controller
mkdir -p ssh logs configs/inventory
cp ~/.ssh/id_ed25519.pub ssh/authorized_keys
chmod 700 ssh
chmod 600 ssh/authorized_keys

cat > controller.override.yml <<'YAML'
services:
  ansible:
    image: allamiro1/ansible-controller:0.29.0
YAML

docker compose -f docker-compose.yml -f controller.override.yml up -d --no-build --wait
```

Before executing a playbook, configure `configs/inventory/hosts.ini`, target
credentials and verified SSH host keys. The supplied `configs/ansible.cfg` has
compatibility-oriented host-key defaults; follow the production SSH trust procedure
in the [main guide](https://github.com/allamiro/ansible-controller#ssh-host-key-checking) rather than
assuming strict target verification is enabled.

```bash
make galaxy                   # wait for/install declared Galaxy content
make pip                      # wait for/install declared Python packages
make preflight STRICT=1       # inspect readiness and configuration risks
make run PLAYBOOK=site.yml     # playbooks/site.yml, after reviewing its targets
```

`make run` is interactive. In CI use a command without `-t`, for example:

```bash
docker exec -i ansible-controller ansible-playbook /configs/playbooks/site.yml
```

SSH into the controller at `ansible@localhost` on port `2222`. Mounts and
credentials are host-managed; recreating the container should preserve them.

## Configuration and persistence

| Container path | Purpose |
| --- | --- |
| `/configs` | Read-write configuration, inventory, requirements and persisted Galaxy content |
| `/configs/playbooks` | Read-only playbooks and project content from the host |
| `/home/ansible/.ssh` | Read-only authorized keys, target credentials and known hosts |
| `/var/log/ansible` | Execution and dependency-install logs |
| `/etc/ssh/host_keys` | Named volume preserving the controller's SSH host identity |

Startup dependency installs run in the background. `make galaxy` and `make pip`
share the startup lock and report install failures; `make preflight` inspects
readiness. Pin your requirements and review failures before running automation.

For Vault password provisioning, SSH trust, dynamic inventory and Windows
configuration, use the maintained [controller guide](https://github.com/allamiro/ansible-controller).
Keep passwords and private keys out of Git, image layers and command examples.

## Optional GitLab workflow

GitLab is optional: direct commands work without it. The repository supplies a
controller-side `ctl-run` integration and project templates for exact-commit sync,
manual execution approval, durable retry tracking, and HTML/JSON/JUnit reports.
Those integration scripts and environment mappings are **configured separately**;
changing an image tag does not install or update a GitLab project.

See [GitLab setup](https://github.com/allamiro/ansible-controller/blob/main/gitlab/MAINTAINER-README.md)
and [sync, approvals, reporting and upgrades](https://github.com/allamiro/ansible-controller/blob/main/gitlab/MESH-ROLLOUTS.md).
For distributed execution, follow the mesh image pages instead.

## Support and license

Support maintenance through [GitHub Sponsors](https://github.com/sponsors/allamiro)
or [Buy Me a Coffee](https://buymeacoffee.com/pcileky2q). Bug reports, documentation
and code contributions are welcome. **Continue free** without registration or a
system-count limit. The automatic terminal notice is confined to mesh images.

[Apache-2.0 project license](https://github.com/allamiro/ansible-controller/blob/main/LICENSE);
bundled dependencies retain their own licenses. Published images are scanned for
fixable HIGH/CRITICAL vulnerabilities and signed with cosign through GitHub OIDC.
See the [release workflow](https://github.com/allamiro/ansible-controller/blob/main/.github/workflows/docker-publish.yml)
for the exact gates and verification commands in the project guides.
