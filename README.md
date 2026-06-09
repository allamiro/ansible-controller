[![CI](https://github.com/allamiro/ansible-controller/actions/workflows/docker-image.yml/badge.svg?branch=main)](https://github.com/allamiro/ansible-controller/actions/workflows/docker-image.yml)
[![Build & Publish](https://github.com/allamiro/ansible-controller/actions/workflows/docker-publish.yml/badge.svg?branch=main)](https://github.com/allamiro/ansible-controller/actions/workflows/docker-publish.yml)
[![Last commit](https://img.shields.io/github/last-commit/allamiro/ansible-controller)](https://github.com/allamiro/ansible-controller)

# Ansible Controller (Docker)

Ubuntu 24.04-based Docker image for running Ansible playbooks with support for SSH, sudo, and external inventory mounts.

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

## Quick start

### 1 — Prepare host directories

```bash
mkdir -p configs/inventory logs ssh

# Place your SSH public key
cp ~/.ssh/id_ed25519.pub ssh/authorized_keys

# Required permissions (OpenSSH StrictModes)
chmod 700 ssh
chmod 600 ssh/authorized_keys
```

### 2 — Start with Docker Compose

```bash
docker compose up -d
```

### 3 — Run a playbook

```bash
# Via Makefile
make run PLAYBOOK=site.yml

# Or directly
docker exec -it ansible-controller ansible-playbook /configs/site.yml
```

### 4 — Open a shell

```bash
make shell
# or
docker exec -it ansible-controller bash
```

### 5 — SSH in (optional)

```bash
ssh -p 2222 ansible@localhost
```

---

## Makefile targets

| Target | Description |
|--------|-------------|
| `make build` | Build the Docker image |
| `make up` | Start the container in the background |
| `make down` | Stop and remove the container |
| `make shell` | Open an interactive bash shell inside the container |
| `make run PLAYBOOK=site.yml` | Run an Ansible playbook |
| `make logs` | Tail container logs |

---

## Running playbooks

```bash
# Basic run
docker exec -it ansible-controller ansible-playbook /configs/site.yml

# Specific inventory file
docker exec -it ansible-controller ansible-playbook \
  -i /configs/inventory/hosts.ini /configs/site.yml

# Dynamic inventory
docker exec -it ansible-controller ansible-playbook \
  -i /configs/inventory/inventory.py /configs/site.yml

# Limit to a specific host or group
docker exec -it ansible-controller ansible-playbook /configs/site.yml \
  --limit webservers

# Pass extra variables
docker exec -it ansible-controller ansible-playbook /configs/site.yml \
  -e "env=production version=1.2.3"

# Run only tasks with specific tags
docker exec -it ansible-controller ansible-playbook /configs/site.yml \
  --tags "install,configure"

# Dry run — show what would change without applying it
docker exec -it ansible-controller ansible-playbook /configs/site.yml --check

# Dry run with diff — show file content changes
docker exec -it ansible-controller ansible-playbook /configs/site.yml --check --diff

# Increase verbosity (-v through -vvvv)
docker exec -it ansible-controller ansible-playbook /configs/site.yml -v
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
ansible-playbook -i /configs/inventory/inventory.py /configs/site.yml
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

---

## Logs

Ansible logs are written to `/var/log/ansible/ansible.log` inside the container and persisted to `./logs/ansible.log` on the host via the volume mount.

---

## Versioning and releases

Every push to `main` is automatically tagged based on [conventional commit](https://www.conventionalcommits.org/) prefixes:

| Commit prefix | Version bump | Example |
|---------------|--------------|---------|
| `fix:` / `perf:` / `refactor:` | patch | `v1.0.0` → `v1.0.1` |
| `feat:` | minor | `v1.0.0` → `v1.1.0` |
| `feat!:` / `BREAKING CHANGE` | major | `v1.0.0` → `v2.0.0` |

The new git tag then triggers the publish workflow which:
- Builds and pushes `v1.2.3`, `v1.2`, `v1`, `latest` tags to both Docker Hub and GHCR
- Creates a GitHub Release with auto-generated changelog

---

## Notes

- **Base image:** Ubuntu 24.04 LTS (Noble Numbat) — standard security support until April 2029, extended to 2034 with Ubuntu Pro.
- If `configs/ansible.cfg` exists on the host it is used automatically; otherwise the image default applies.
- The `ansible` user (uid 1000) is the only user inside the container. `PermitRootLogin no` is enforced.
- SSH host keys are generated at image build time (`ssh-keygen -A`).
- A `HEALTHCHECK` verifies sshd is listening on port 22. Check container health with `docker ps`.

---

## Links

- Docker Hub: https://hub.docker.com/r/allamiro1/ansible-controller
- GHCR: https://ghcr.io/allamiro/ansible-controller
