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

Ubuntu 26.04-based Docker image that packages Ansible, OpenSSH, and everything needed to manage remote infrastructure. Write your playbooks on the host, mount them into the container, and run — no need to install Ansible locally.

## Features

- **Zero local dependencies** — only Docker required on the host
- **SSH built-in** — connect into the controller or out to managed hosts
- **Mount-based workflow** — playbooks, inventory, and SSH keys live on the host; no rebuild needed to change them
- **Multi-platform** — ships `linux/amd64` and `linux/arm64` (Apple Silicon, AWS Graviton)
- **Auto-versioned** — every push to `main` is automatically tagged via conventional commits
- **Published to two registries** — Docker Hub and GitHub Container Registry (GHCR)
- **Security hardened** — non-root `ansible` user, `PermitRootLogin no`, pip-upgraded CVE packages, unreachable vendored binaries stripped

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [How it works](#how-it-works)
- [Quick start](#quick-start)
- [Pull the image](#pull-the-image)
- [Makefile targets](#makefile-targets)
- [Running playbooks](#running-playbooks)
- [Adding roles from a GitHub repository](#adding-roles-from-a-github-repository)
- [Adding roles from Ansible Galaxy](#adding-roles-from-ansible-galaxy)
- [Ad-hoc commands](#ad-hoc-commands)
- [Build from source](#build-from-source)
- [Run with Docker (manual)](#run-with-docker-manual)
- [Dynamic inventory](#dynamic-inventory)
- [Cloud dynamic inventory (AWS / Azure / GCP)](#cloud-dynamic-inventory-aws--azure--gcp)
- [Managing Windows hosts (WinRM)](#managing-windows-hosts-winrm)
- [Ansible Vault](#ansible-vault)
- [Linting playbooks](#linting-playbooks)
- [Faster runs with Mitogen](#faster-runs-with-mitogen)
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
| `make galaxy` | Install roles and collections from `configs/requirements.yml` |
| `make galaxy-force` | Re-install / update Galaxy content to the pinned versions |
| `make pip` | Install extra Python packages from `configs/pip-requirements.txt` |
| `make lint` | Lint everything under `playbooks/` with ansible-lint |
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

## Adding roles from a GitHub repository

Any role published as a git repository can be installed directly — useful for roles that aren't on Galaxy, forks, or a version pinned to a specific branch/tag/commit.

Roles are declared in `configs/requirements.yml` and installed into `configs/.galaxy/` on the host (a read-write mount), so they persist across restarts and need no image rebuild. Everything declared there is installed **automatically when the container starts**, in the background (logged to `logs/galaxy-install.log`); run `make galaxy` after `make up` to install on demand — it shares a lock with the startup installer, so it also blocks until any in-flight startup install has finished, guaranteeing content is ready before you run playbooks. `configs/ansible.cfg` already points `roles_path` there, so installed roles resolve automatically.

### 1 — Declare the role

Add a git source to `configs/requirements.yml`. For example, to install [geerlingguy/ansible-role-nginx](https://github.com/geerlingguy/ansible-role-nginx):

```yaml
---
roles:
  - src: https://github.com/geerlingguy/ansible-role-nginx
    name: nginx          # directory name the role installs as — reference this in playbooks
    version: master      # branch, tag, or commit SHA to pin to
```

### 2 — Install it

```bash
make up        # the container must be running
make galaxy    # installs everything declared in requirements.yml
```

Use `make galaxy-force` later to update an already-installed role to the version in the file.

### 3 — Use it in a playbook

Reference the role by the `name` you set above:

```yaml
- name: Configure web servers
  hosts: webservers
  roles:
    - nginx
```

```bash
make run PLAYBOOK=site.yml
```

---

## Adding roles from Ansible Galaxy

When a role is published on [Ansible Galaxy](https://galaxy.ansible.com/), reference it by its Galaxy name (`namespace.role`) instead of a git URL. Galaxy also resolves the role's dependencies automatically.

### 1 — Declare the role (and any collections)

```yaml
---
roles:
  - name: geerlingguy.nginx
    version: 3.2.0          # pin so installs are reproducible
  - name: geerlingguy.docker
    version: 7.4.2

collections:
  - name: community.docker  # ansible.posix and community.general ship in the image
    version: ">=4.0.0,<5.0.0"
```

### 2 — Install it

```bash
make up        # the container must be running
make galaxy    # installs everything declared in requirements.yml
```

Both `roles_path` and `collections_path` in `configs/ansible.cfg` already point at `/configs/.galaxy/`, so installed content is found automatically.

### 3 — Use it in a playbook

```yaml
- name: Install Docker
  hosts: all
  roles:
    - geerlingguy.docker
```

```bash
make run PLAYBOOK=site.yml
```

> **Tip:** Inspect installed content from inside the container:
> ```bash
> make shell
> ansible-galaxy list                          # installed roles + versions
> ansible-galaxy role info geerlingguy.nginx   # details for a Galaxy role
> ```

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

## Cloud dynamic inventory (AWS / Azure / GCP)

Pull live inventory from your cloud provider instead of maintaining a static hosts file. Each provider needs its **collection** (declared in `configs/requirements.yml`) and its **Python SDK** (declared in `configs/pip-requirements.txt`) — both are installed automatically when the container starts, or on demand with `make galaxy` and `make pip`.

| Provider | Collection (`requirements.yml`) | SDK (`pip-requirements.txt`) | Inventory plugin |
|----------|--------------------------------|------------------------------|------------------|
| AWS | `amazon.aws` | `boto3` | `amazon.aws.aws_ec2` |
| Azure | `azure.azcollection` | `azure-identity`, `azure-mgmt-*` | `azure.azcollection.azure_rm` |
| GCP | `google.cloud` | `google-auth`, `requests` | `google.cloud.gcp_compute` |

Commented, version-pinned entries for all three providers ship in both files. In `pip-requirements.txt` simply uncomment the lines; in `requirements.yml` replace the empty `collections: []` list at the bottom with a `collections:` block containing the entries you need (the commented example block shows the exact syntax). Example AWS setup:

```yaml
# configs/requirements.yml
collections:
  - name: amazon.aws
    version: ">=9.0.0,<10.0.0"
```

```
# configs/pip-requirements.txt
boto3>=1.34,<2
```

```yaml
# configs/inventory/aws_ec2.yml — filename must end in aws_ec2.yml
plugin: amazon.aws.aws_ec2
regions:
  - us-east-1
keyed_groups:
  - key: tags.Role
    prefix: role
```

```bash
make up && make galaxy && make pip   # galaxy/pip also wait for the startup installs
docker exec -it ansible-controller \
  ansible-inventory -i /configs/inventory/aws_ec2.yml --graph
```

Provide cloud credentials the usual way (environment variables on the container, or credential files mounted under `configs/` and referenced from the inventory file).

---

## Managing Windows hosts (WinRM)

`pywinrm` (with NTLM support) is baked into the image, so Windows hosts work out of the box over WinRM:

```ini
# configs/inventory/hosts.ini
[windows]
win-server1 ansible_host=192.168.1.20

[windows:vars]
ansible_connection=winrm
ansible_user=Administrator
ansible_winrm_transport=ntlm
ansible_port=5986
# the sudo become defaults in ansible.cfg don't apply to Windows
ansible_become=false
# 'ignore' is for labs only — validate certs in production
# (note: INI inventory values keep trailing text, so comments must stay on their own line)
ansible_winrm_server_cert_validation=ignore
```

```bash
docker exec -it ansible-controller ansible windows -m ansible.windows.win_ping
```

The `ansible.windows` collection is not baked in — declare it (pinned) in `configs/requirements.yml`. The Kerberos transport compiles against native libraries that don't survive container recreation, so bake it into a small derived image instead of installing at runtime:

```dockerfile
# Dockerfile.kerberos
FROM allamiro1/ansible-controller:latest
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc python3-dev libkrb5-dev krb5-user \
 && pip3 install --no-cache-dir --break-system-packages 'pyspnego[kerberos]>=0.10,<1' \
 && apt-get purge -y --auto-remove gcc python3-dev libkrb5-dev \
 && rm -rf /var/lib/apt/lists/*
```

```bash
docker build -f Dockerfile.kerberos -t ansible-controller:kerberos .
# then use this tag in docker-compose.yml / docker run
```

---

## Ansible Vault

Two ways to supply the vault password — pick one:

**Option A — password file (simplest).** Drop the password in `configs/.vault_pass` (the path is gitignored so it can't be committed):

```bash
echo 'my-vault-password' > configs/.vault_pass
chmod 600 configs/.vault_pass
```

**Option B — environment variable (no file on the host).** Export `ANSIBLE_VAULT_PASSWORD` and uncomment the matching line in `docker-compose.yml`; the entrypoint writes it to a file readable only by the `ansible` user inside the container.

Either way the entrypoint copies the password to a file readable only by the `ansible` user and exports `ANSIBLE_VAULT_PASSWORD_FILE` to **all SSH sessions** — interactive logins and one-shot `ssh host command` runs alike (via `pam_env`) — so vaulted content just works:

```bash
docker exec -it ansible-controller ansible-vault encrypt_string 'secret123' --name db_password
ssh -p 2222 ansible@localhost ansible-playbook /configs/playbooks/site.yml   # vault decrypts automatically
```

For `docker exec` (which bypasses PAM), run through `bash -lc` or pass `--vault-password-file` explicitly:

```bash
docker exec -it ansible-controller bash -lc 'ansible-playbook /configs/playbooks/site.yml'
```

---

## Linting playbooks

[ansible-lint](https://ansible-lint.readthedocs.io/) is baked into the image:

```bash
make lint                                    # lints everything under playbooks/
# or lint a single file (run from the playbooks dir so config discovery works):
docker exec -it ansible-controller sh -c 'cd /configs/playbooks && ansible-lint site.yml'
```

Customize rules with a `.ansible-lint` file in the `playbooks/` directory — both commands run from there, which is where ansible-lint looks for its configuration.

---

## Faster runs with Mitogen

[Mitogen](https://mitogen.networkgenomics.com/ansible_detailed.html) is baked into the image (disabled by default) with its strategy plugin already on Ansible's default search path. It multiplexes SSH connections and can cut playbook runtime substantially on large inventories. Enable it by uncommenting one line in `configs/ansible.cfg`:

```ini
strategy = mitogen_linear
```

Leave it disabled if you depend on the `free` strategy or strategy-sensitive plugins — Mitogen replaces the linear strategy wholesale.

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

## SSH host-key checking

By default the shipped `configs/ansible.cfg` **disables** SSH host-key checking:

```ini
[defaults]
host_key_checking = False

[ssh_connection]
ssh_args = -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no
```

This is a **development convenience** — it avoids host-key prompts against lab
hosts whose keys change often — but it is **not production-safe**: it disables
SSH man-in-the-middle protection, so a spoofed or hijacked host is trusted
silently. The insecure default is kept for backward compatibility and is slated
to flip to strict in a future major release.

**For production, enable strict checking with a managed `known_hosts`:**

```ini
[defaults]
host_key_checking = True

[ssh_connection]
ssh_args = -o UserKnownHostsFile=/configs/known_hosts -o StrictHostKeyChecking=yes
```

Pre-populate the `known_hosts` file on the host (it persists via the `./configs`
mount). **Verify the keys out-of-band before trusting them.** `ssh-keyscan`
records whatever key answers on the network, so over an untrusted or compromised
path it will happily capture an attacker's key — its manual explicitly warns
against building `known_hosts` "without verifying the keys":

```bash
# 1. Fetch candidate keys — WITHOUT -H, so each fingerprint stays attributable to
#    its plaintext host in the next step (-H hashes the hostnames):
#    The candidate file gets a private random name. A fixed path like
#    /tmp/known_hosts.new on a multi-user host is a classic spoof target: another
#    user can pre-create or symlink it, seeding the file you later trust:
kh_new=$(mktemp)
ssh-keyscan server1 server2 > "$kh_new"

#    A host reached on a non-default port (ansible_port) must be scanned WITH -p.
#    OpenSSH looks such a host up as [host]:port, and ssh-keyscan only writes that
#    bracketed form when -p is given — scan it without and you store a plain
#    `server3` entry that never matches, so StrictHostKeyChecking=yes rejects the
#    host even though its key was verified:
ssh-keyscan -p 2222 server3 >> "$kh_new"

#    Scan the address Ansible actually CONNECTS to, which is `ansible_host` when
#    the inventory sets one and the inventory name otherwise. OpenSSH looks the
#    key up under the address it dials, so a key pinned under an inventory alias
#    is never found and strict checking rejects the host:
#      web01 ansible_host=10.0.0.5   ->   ssh-keyscan 10.0.0.5   (not web01)

# 2. Compare each fingerprint against a TRUSTED source before pinning — the host
#    console, the cloud provider's API, a config-management fact, or the host's
#    own /etc/ssh/ssh_host_*_key.pub obtained over a channel you already trust:
ssh-keygen -lf "$kh_new"

# 3. Install — but only if every host actually made it into the candidate file.
#    ssh-keyscan skips hosts it cannot reach and still exits 0 when only some of
#    them failed, so an unguarded run would delete a briefly-down or mistyped
#    host's good key below and have nothing to put back, turning a transient
#    outage into a host strict checking then refuses to connect to. The check
#    therefore GATES the removal rather than just warning about it.
#
#    Removing each superseded entry first is what stops a rekeyed host from
#    staying trusted on its OLD key (a match on ANY entry passes). `-R` takes a
#    single host, so keep the loop — a second `-R` overrides the first instead of
#    removing both — and name non-default-port hosts in the bracketed form they
#    were stored under.
#
#    Every mutation happens on TEMP FILES; the live file changes only via one
#    atomic rename at the end. Any earlier failure — an unreadable existing file,
#    a failed removal, a full disk while writing the replacement — aborts with
#    the live file byte-identical. A plain `>` redirect could not promise that:
#    it truncates the live file BEFORE writing, so an interruption mid-write
#    strands it empty or partial. The subshell + set -e keeps the block safe to
#    paste (a failure exits the subshell, not your shell), and the explicit
#    chmod means a first-ever pin is readable by the container's uid 1000 even
#    under a restrictive host umask like 077 (known_hosts holds public keys;
#    0644 is what OpenSSH itself creates).
missing=
for h in server1 server2 '[server3]:2222'; do
  ssh-keygen -F "$h" -f "$kh_new" >/dev/null || missing="$missing $h"
done

if [ -n "$missing" ]; then
  echo "NOT scanned:$missing — fix and re-scan; known_hosts left unchanged"
else
  # The subshell must stand ALONE, with its status tested on the next line.
  # Chaining it into `( ... ) && echo ... || echo ...` would quietly disable the
  # `set -e` inside: the shell ignores errexit in every non-final command of an
  # AND-OR list, so failures would stop aborting the update.
  (
    set -e
    work=$(mktemp); new=
    trap 'rm -f "$work" "$work.old" "$new"' EXIT
    [ ! -e configs/known_hosts ] || cp configs/known_hosts "$work"
    for h in server1 server2 '[server3]:2222'; do
      ssh-keygen -R "$h" -f "$work" >/dev/null 2>&1
    done
    new=$(mktemp configs/known_hosts.XXXXXX)
    cat "$work" "$kh_new" > "$new"
    chmod 644 "$new"
    mv "$new" configs/known_hosts && new=
  )
  ok=$?
  if [ "$ok" -eq 0 ]; then echo "known_hosts updated"; else echo "FAILED — known_hosts left unchanged"; fi
fi

# 4. (optional) hash the hostnames at rest once pinned:
#    Gated on the update above having succeeded — pasted verbatim after a failed
#    or skipped update, an unguarded hash would still rewrite the live file:
[ "${ok:-1}" -eq 0 ] && ssh-keygen -Hf configs/known_hosts && rm -f configs/known_hosts.old
```

Better still, provision authoritative host keys directly from your
config-management system or golden image instead of scanning at all.

If you prefer trust-on-first-use over pre-pinning every host, use
`StrictHostKeyChecking=accept-new`: Ansible records each host key the first time
it connects and then fails if a key later changes. That still catches
key-substitution attacks after the first contact, unlike the `=no` default.

`accept-new` has to **write** the first key, so `configs/known_hosts` must be
writable by the container user (uid 1000) — otherwise the write silently fails and
every session keeps treating keys as new. Prepare it on the host:

```bash
touch configs/known_hosts
sudo chown 1000:1000 configs/known_hosts   # the container's ansible user is uid 1000
chmod 600 configs/known_hosts
```

The pre-pinned `StrictHostKeyChecking=yes` recipe above needs the file only
*readable*, so it sidesteps this ownership requirement entirely.

> The distributed execution mesh (see [`mesh/`](mesh/README.md)) will use strict,
> managed host-key checking as its default from the start — this relaxed setting
> is scoped to the existing direct controller only.

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

### Image signing (cosign)

Every published multi-arch manifest is signed with [cosign](https://docs.sigstore.dev/cosign/signing/overview/) using keyless GitHub OIDC — no long-lived signing keys exist. Verify a pulled image before running it:

```bash
cosign verify \
  --certificate-identity-regexp 'https://github\.com/allamiro/ansible-controller/\.github/workflows/docker-publish\.yml@.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/allamiro/ansible-controller:latest
```

The same works against `docker.io/allamiro1/ansible-controller`. A valid signature proves the image was built and published by this repository's GitHub Actions workflow, not tampered with in transit or on the registry.

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

- **Base image:** Ubuntu 26.04 LTS — standard security support until 2031, extended further with Ubuntu Pro.
- **CVE surface:** the build strips two sources of findings that `apt-get upgrade` cannot reach, and the image scans clean at CRITICAL/HIGH.
  - Canonical drops `/usr/bin/pebble` into the OCI rootfs outside dpkg, so no package owns it and it can never be patched in place. This image runs `entrypoint.sh` + sshd as PID 1 and never invokes pebble, so it is deleted along with `/var/lib/pebble` — taking eight Go stdlib CVEs with it.
  - pip bundles its own pinned copies of a few libraries under `pip/_vendor` and advertises them in `vendor.txt` and `bom.cdx.json`, which scanners read independently of what is actually installed. `docker/patch-pip-vendor.py` re-vendors msgpack from the patched release installed alongside it and deletes the vendored `pkg_resources` tree (dead code — pip declares that metadata backend unusable on Python 3.14+), updating both manifests to match. The script asserts its own result, so a future pip release that reshapes `_vendor` fails the build rather than silently reintroducing the findings. The redundant apt `python3-pip`, fully shadowed by the pip in `/usr/local`, is purged.
- **Ansible:** the image ships the current `ansible-core` (via pip) plus the `ansible.posix` and `community.general` collections — not the ~280 MiB `ansible` community bundle. Declare any additional collections or roles in `configs/requirements.yml`; they are installed automatically at container start (or on demand with `make galaxy`) into the host-persisted `configs/.galaxy/` directory, no rebuild needed.
- If `configs/ansible.cfg` exists on the host it is used automatically; otherwise the image default applies.
- The `ansible` user (uid 1000) is the only user inside the container. `PermitRootLogin no` is enforced.
- SSH host keys are generated on first container start (not baked into the image, so every deployment gets unique keys). Keys live in `/etc/ssh/host_keys`, and the compose file persists that directory in the `ssh-host-keys` volume so they survive container recreation (only the keys are persisted — `sshd_config` and `moduli` keep tracking the image). Without a volume on `/etc/ssh/host_keys`, recreating the container generates new keys and SSH clients will warn about a changed host key.
- A `HEALTHCHECK` verifies sshd is listening on port 22. Check container health with `docker ps`.

---

<div align="center">
  <sub>Built with care · <a href="https://hub.docker.com/r/allamiro1/ansible-controller">Docker Hub</a> · <a href="https://ghcr.io/allamiro/ansible-controller">GHCR</a></sub>
</div>
