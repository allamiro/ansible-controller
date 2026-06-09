[![CI](https://github.com/allamiro/ansible-controller/actions/workflows/docker-image.yml/badge.svg?branch=main)](https://github.com/allamiro/ansible-controller/actions/workflows/docker-image.yml)
[![Build & Publish](https://github.com/allamiro/ansible-controller/actions/workflows/docker-publish.yml/badge.svg?branch=main)](https://github.com/allamiro/ansible-controller/actions/workflows/docker-publish.yml)
[![Last commit](https://img.shields.io/github/last-commit/allamiro/ansible-controller)](https://github.com/allamiro/ansible-controller)

<div align="center">
  <img src="assets/ansible-controller.png" alt="Ansible Controller" width="350"/>
  <h1>Ansible Controller</h1>
  <p><strong>Run Ansible playbooks from any machine — no local Ansible installation required.</strong></p>

  [![Docker Pulls](https://img.shields.io/docker/pulls/allamiro1/ansible-controller)](https://hub.docker.com/r/allamiro1/ansible-controller)
  [![Image Size](https://img.shields.io/docker/image-size/allamiro1/ansible-controller/latest)](https://hub.docker.com/r/allamiro1/ansible-controller)
  [![License](https://img.shields.io/github/license/allamiro/ansible-controller)](LICENSE)
  [![Latest Tag](https://img.shields.io/github/v/tag/allamiro/ansible-controller?label=version)](https://github.com/allamiro/ansible-controller/releases)
</div>

---

Ubuntu 24.04-based Docker image that packages Ansible, OpenSSH, and everything needed to manage remote infrastructure. Write your playbooks on the host, mount them into the container, and run — no need to install Ansible locally.

## Features

- **Zero local dependencies** — only Docker required on the host
- **SSH built-in** — connect into the controller or out to managed hosts
- **Mount-based workflow** — playbooks, inventory, and SSH keys live on the host; no rebuild needed to change them
- **Multi-platform** — ships `linux/amd64` and `linux/arm64` (Apple Silicon, AWS Graviton)
- **Auto-versioned** — every push to `main` is automatically tagged via conventional commits
- **Published to two registries** — Docker Hub and GitHub Container Registry (GHCR)
- **Security hardened** — non-root `ansible` user, `PermitRootLogin no`, pip-upgraded CVE packages

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [How it works](#how-it-works)
- [Quick start](#quick-start)
- [Pull the image](#pull-the-image)
- [Makefile targets](#makefile-targets)
- [Running playbooks](#running-playbooks)
- [Ad-hoc commands](#ad-hoc-commands)
- [Build from source](#build-from-source)
- [Run with Docker (manual)](#run-with-docker-manual)
- [Dynamic inventory](#dynamic-inventory)
- [SSH keys for managed hosts](#ssh-keys-for-managed-hosts)
- [SSH agent forwarding](#ssh-agent-forwarding-optional)
- [Logs](#logs)
- [Versioning and releases](#versioning-and-releases)
- [Contributing](#contributing)
- [License](#license)
- [Notes](#notes)

---

## Prerequisites

| Requirement | Minimum version | Notes |
|-------------|----------------|-------|
| Docker Engine | 20.10+ | [Install guide](https://docs.docker.com/engine/install/) |
| Docker Compose | V2 (`docker compose`) | Included with Docker Desktop |

No other tools required. Ansible runs entirely inside the container.

---

## How it works

You write and store your playbooks on your host machine. The container provides Ansible and SSH. You mount your playbook directory into the container and tell Ansible where to find it.

```
Host machine                        Container
──────────────────────────────      ────────────────────────────────
~/my-project/
  playbooks/        ──mount──→      /configs/
    site.yml                          playbooks/site.yml
    roles/                            roles/
  inventory/        ──mount──→        inventory/hosts.ini
  ssh/              ──mount──→      /home/ansible/.ssh/
    id_ed25519                        id_ed25519  (used to reach remote hosts)
```

The `docker-compose.yml` included in the repo already has all four mounts configured. If you add playbooks outside the `playbooks/` directory, add an extra volume entry for that path.

---

## Quick start

### 1 — Clone the repo

```bash
git clone https://github.com/allamiro/ansible-controller.git
cd ansible-controller
```

The repo already includes the full directory structure, `docker-compose.yml`, `ansible.cfg`, and example playbooks in `playbooks/`. Nothing to create manually.

### 2 — Add your servers to the inventory

```bash
# Edit configs/inventory/hosts.ini and list your servers
cat > configs/inventory/hosts.ini << 'EOF'
[all]
192.168.1.10
192.168.1.11
192.168.1.12

[webservers]
192.168.1.10
192.168.1.11

[databases]
192.168.1.12
EOF
```

### 3 — Generate an SSH key and copy it to your servers

```bash
# Generate a key pair into ssh/
ssh-keygen -t ed25519 -C "ansible-controller" -f ssh/id_ed25519 -N ""
chmod 600 ssh/id_ed25519

# Copy the public key to every unique host in the inventory
for host in $(grep -v '^\[' configs/inventory/hosts.ini \
             | grep -v '^#' \
             | grep -v '^$' \
             | sort -u); do
  ssh-copy-id -i ssh/id_ed25519.pub user@$host
done
```

### 4 — Start the container

```bash
docker compose up -d
```

### 5 — Test connectivity

```bash
# Run the included ping playbook against all servers
docker exec -it ansible-controller \
  ansible-playbook /configs/playbooks/ping.yml
```

All hosts should return `pong`. If they do, Ansible can reach your servers.

### 6 — Add your own playbooks and run them

Drop your playbooks into the `playbooks/` directory on the host:

```bash
# Example: create a simple playbook
cat > playbooks/deploy.yml << 'EOF'
---
- name: Deploy application
  hosts: webservers
  tasks:
    - name: Ensure nginx is installed
      ansible.builtin.apt:
        name: nginx
        state: present
      become: true
EOF

# Run it
docker exec -it ansible-controller \
  ansible-playbook /configs/playbooks/deploy.yml
```

### 7 — Open a shell inside the container (optional)

```bash
make shell
# or
docker exec -it ansible-controller bash
```

---

## Pull the image

**Docker Hub**
```bash
docker pull allamiro1/ansible-controller:latest
```

**GitHub Container Registry (GHCR)**
```bash
docker pull ghcr.io/allamiro/ansible-controller:latest
```

### Image tags

| Tag | Description |
|-----|-------------|
| `latest` | Most recent successful build from `main` |
| `sha-XXXXXXX` | Immutable pointer to a specific commit — use for pinned/reproducible deployments |
| `v1.2.3` | Semantic version — published when a `v*` git tag is pushed |
| `main` | Tracks the `main` branch |

---

## Makefile targets

| Target | Description |
|--------|-------------|
| `make build` | Build the Docker image locally |
| `make up` | Start the container in the background |
| `make down` | Stop and remove the container |
| `make shell` | Open an interactive bash shell inside the container |
| `make run PLAYBOOK=site.yml` | Run an Ansible playbook |
| `make logs` | Tail container logs |

---

## Running playbooks

```bash
# Basic run against the default inventory in ansible.cfg
docker exec -it ansible-controller \
  ansible-playbook /configs/playbooks/site.yml

# Specify a user to connect as on the remote hosts
docker exec -it ansible-controller \
  ansible-playbook /configs/playbooks/site.yml -u deploy

# Specify a different inventory file
docker exec -it ansible-controller \
  ansible-playbook /configs/playbooks/site.yml \
  -i /configs/inventory/hosts.ini

# Run against a single host
docker exec -it ansible-controller \
  ansible-playbook /configs/playbooks/site.yml \
  -i "192.168.1.10," -u deploy

# Limit to a specific group or host from inventory
docker exec -it ansible-controller \
  ansible-playbook /configs/playbooks/site.yml --limit webservers

# Pass extra variables
docker exec -it ansible-controller \
  ansible-playbook /configs/playbooks/site.yml \
  -e "env=production version=1.2.3"

# Run only tasks with specific tags
docker exec -it ansible-controller \
  ansible-playbook /configs/playbooks/site.yml --tags "install,configure"

# Dry run — show what would change without applying it
docker exec -it ansible-controller \
  ansible-playbook /configs/playbooks/site.yml --check --diff

# Increase verbosity for troubleshooting
docker exec -it ansible-controller \
  ansible-playbook /configs/playbooks/site.yml -vv
```

### With roles

Roles must be reachable from inside the container. If your project layout is:

```
playbooks/
  site.yml
  roles/
    webserver/
    database/
```

They are already available at `/configs/playbooks/roles/` inside the container. Reference them normally in your playbook:

```yaml
- hosts: webservers
  roles:
    - webserver
    - database
```

If roles live in a separate directory, mount them and set `roles_path` in `configs/ansible.cfg`:

```ini
[defaults]
roles_path = /configs/roles:/configs/playbooks/roles
```

---

## Ad-hoc commands

```bash
# Ping all hosts to verify connectivity
docker exec -it ansible-controller ansible all -m ping

# Ping a specific group
docker exec -it ansible-controller ansible webservers -m ping

# Run a shell command on all hosts
docker exec -it ansible-controller ansible all -m shell -a "uptime"

# Check disk space
docker exec -it ansible-controller ansible all -m shell -a "df -h"

# Gather all facts from a host
docker exec -it ansible-controller ansible server1 -m setup

# Gather a specific fact
docker exec -it ansible-controller ansible all -m setup \
  -a "filter=ansible_os_family"

# Copy a file to all hosts
docker exec -it ansible-controller ansible all -m copy \
  -a "src=/configs/file.txt dest=/tmp/file.txt"

# Install a package (requires become)
docker exec -it ansible-controller ansible all -m apt \
  -a "name=nginx state=present" --become

# Restart a service
docker exec -it ansible-controller ansible all -m service \
  -a "name=nginx state=restarted" --become

# Reboot all hosts and wait for them to come back
docker exec -it ansible-controller ansible all -m reboot --become
```

---

## Build from source

```bash
git clone https://github.com/allamiro/ansible-controller.git
cd ansible-controller
docker build -t ansible-controller:local -f docker/Dockerfile .
```

---

## Run with Docker (manual)

```bash
# Prepare ssh/ directory first (see Quick start step 1)

docker run -d --name ansible-controller \
  -p 2222:22 \
  -v "$PWD/configs":/configs:rw \
  -v "$PWD/playbooks":/configs/playbooks:ro \
  -v "$PWD/logs":/var/log/ansible:rw \
  -v "$PWD/ssh":/home/ansible/.ssh:ro \
  ansible-controller:latest
```

> **Note:** Mount the entire `ssh/` directory (not a single file). Set `chmod 700 ssh` and `chmod 600 ssh/authorized_keys` on the host before starting.

---

## Dynamic inventory

A dynamic inventory script is included at `configs/inventory/inventory.py`. It reads hosts from `configs/inventory/hosts.json` when present and falls back gracefully when the file is absent.

**hosts.json example:**
```json
{
  "all": {
    "hosts": ["192.168.1.10", "192.168.1.11"],
    "vars": { "ansible_user": "ansible" }
  },
  "webservers": {
    "hosts": ["192.168.1.10"],
    "vars": {}
  }
}
```

**Use it:**
```bash
docker exec -it ansible-controller \
  ansible-playbook -i /configs/inventory/inventory.py /configs/playbooks/site.yml
```

---

## SSH keys for managed hosts

To allow the controller to connect passwordlessly to your managed servers, generate a key pair on the host and let the container pick it up via the volume mount.

```bash
# Generate the key pair into the ssh/ directory
ssh-keygen -t ed25519 -C "ansible-controller" -f ssh/id_ed25519 -N ""
chmod 600 ssh/id_ed25519
```

Copy the public key to every server you want Ansible to manage:

```bash
ssh-copy-id -i ssh/id_ed25519.pub user@server1
ssh-copy-id -i ssh/id_ed25519.pub user@server2
```

Tell Ansible to use the key by adding this to `configs/ansible.cfg`:

```ini
[defaults]
private_key_file = /home/ansible/.ssh/id_ed25519
```

The private key is available inside the container at `/home/ansible/.ssh/id_ed25519` via the volume mount. Restart the container after adding the key if it was already running.

---

## SSH agent forwarding (optional)

To use your host SSH keys inside the container without copying them to disk, uncomment the volume and environment entries in `docker-compose.yml`:

```yaml
volumes:
  - ${SSH_AUTH_SOCK}:/run/host-services/ssh-auth.sock
environment:
  - SSH_AUTH_SOCK=/run/host-services/ssh-auth.sock
```

Make sure your key is loaded on the host first:

```bash
ssh-add ~/.ssh/id_ed25519
```

---

## Logs

Ansible logs are written to `/var/log/ansible/ansible.log` inside the container and persisted to `./logs/ansible.log` on the host via the volume mount.

```bash
# Tail logs from the host
tail -f logs/ansible.log

# Or from inside the container
docker exec -it ansible-controller tail -f /var/log/ansible/ansible.log
```

---

## Versioning and releases

Every push to `main` is automatically tagged based on [conventional commit](https://www.conventionalcommits.org/) prefixes:

| Commit prefix | Version bump | Example |
|---------------|--------------|---------|
| `fix:` / `perf:` / `refactor:` | patch | `v1.0.0` → `v1.0.1` |
| `feat:` | minor | `v1.0.0` → `v1.1.0` |
| `feat!:` / `BREAKING CHANGE` | major | `v1.0.0` → `v2.0.0` |

The new git tag triggers the publish workflow which:
- Builds and pushes `v1.2.3`, `v1.2`, `v1`, `latest` tags to both Docker Hub and GHCR
- Creates a GitHub Release with auto-generated changelog

---

## Contributing

Contributions are welcome. Please open an issue before submitting a pull request so the change can be discussed first.

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/my-feature`
3. Commit using [conventional commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:` etc.
4. Push and open a pull request against `main`

Bug reports, feature requests, and documentation improvements are all appreciated.

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).

---

## Notes

- **Base image:** Ubuntu 24.04 LTS (Noble Numbat) — standard security support until April 2029, extended to 2034 with Ubuntu Pro.
- If `configs/ansible.cfg` exists on the host it is used automatically; otherwise the image default applies.
- The `ansible` user (uid 1000) is the only user inside the container. `PermitRootLogin no` is enforced.
- SSH host keys are generated at image build time (`ssh-keygen -A`).
- A `HEALTHCHECK` verifies sshd is listening on port 22. Check container health with `docker ps`.

---

<div align="center">
  <sub>Built with care · <a href="https://hub.docker.com/r/allamiro1/ansible-controller">Docker Hub</a> · <a href="https://ghcr.io/allamiro/ansible-controller">GHCR</a></sub>
</div>
