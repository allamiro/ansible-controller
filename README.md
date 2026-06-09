[![CI](https://github.com/allamiro/ansible-controller/actions/workflows/docker-image.yml/badge.svg?branch=main)](https://github.com/allamiro/ansible-controller/actions/workflows/docker-image.yml)
[![Build & Publish](https://github.com/allamiro/ansible-controller/actions/workflows/docker-publish.yml/badge.svg?branch=main)](https://github.com/allamiro/ansible-controller/actions/workflows/docker-publish.yml)
[![Last commit](https://img.shields.io/github/last-commit/allamiro/ansible-controller)](https://github.com/allamiro/ansible-controller)

# Ansible Controller (Docker)

Ubuntu-based Docker image for running Ansible playbooks with support for SSH, sudo, and external inventory mounts.

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

Every successful push to `main` updates the `latest` and `sha-XXXXXXX` image tags automatically. To publish a versioned release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

This triggers the publish workflow which:
- Builds and pushes `v1.0.0`, `v1.0`, `v1` tags to both Docker Hub and GHCR
- Creates a GitHub Release with auto-generated changelog

---

## Notes

- If `configs/ansible.cfg` exists on the host it is used automatically; otherwise the image default applies.
- The `ansible` user (uid 1000) is the only user inside the container. `PermitRootLogin no` is enforced.
- SSH host keys are generated at image build time (`ssh-keygen -A`).
- A `HEALTHCHECK` verifies sshd is listening on port 22. Check container health with `docker ps`.

---

## Links

- Docker Hub: https://hub.docker.com/r/allamiro1/ansible-controller
- GHCR: https://ghcr.io/allamiro/ansible-controller
