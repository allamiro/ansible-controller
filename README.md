[![CI](https://github.com/allamiro/ansible-controller/actions/workflows/docker-image.yml/badge.svg?branch=main)](https://github.com/allamiro/ansible-controller/actions/workflows/docker-image.yml)
[![Build & Publish](https://github.com/allamiro/ansible-controller/actions/workflows/docker-publish.yml/badge.svg?branch=main)](https://github.com/allamiro/ansible-controller/actions/workflows/docker-publish.yml)
[![Last commit](https://img.shields.io/github/last-commit/allamiro/ansible-controller)](https://github.com/allamiro/ansible-controller)
[![GitHub release](https://img.shields.io/github/v/release/allamiro/ansible-controller)](https://github.com/allamiro/ansible-controller/releases)
[![Release date](https://img.shields.io/github/release-date/allamiro/ansible-controller)](https://github.com/allamiro/ansible-controller/releases)
# Ansible Controller (Docker)

Ubuntu-based Docker image for running Ansible playbooks with support for SSH, sudo, and external inventory mounts.


## Bring-your-own config/inventory

- Put `configs/ansible.cfg` and `configs/inventory/hosts.ini` on the host.
- Optionally add playbooks under `configs/`.

## Build & run - Makefile

```
make build
make up
# SSH in (optional)
ssh -p 2222 ansible@localhost
# Or exec a shell
make sh
```

## Build the image (Docker)

```
docker build -t ansible-ctrl ./docker

```
## Run with Docker 

```

# Start the container (SSH exposed on host port 2222)
docker run -d --name ansible-ctrl \
  -p 2222:22 \
  -v "$PWD/configs":/configs:rw \
  -v "$PWD/logs":/var/log/ansible:rw \
  -v "$PWD/ssh/authorized_keys":/home/ansible/.ssh/authorized_keys:ro \
  ansible-ctrl:latest

# Open a shell inside the container
docker exec -it ansible-ctrl bash

# From that shell, run Ansible using your mounted config/inventory
ansible --version
ansible -m ping all
ansible-playbook /configs/playbooks/site.yml


```


## Run with Docker compose


```
docker compose up -d
docker compose exec ansible bash
# then run Ansible:
ansible -m ping all
ansible-playbook /configs/playbooks/site.yml

```


## Inside the Container 

```
ansible --version             # confirms which config file is used
ansible -m ping all
ansible-playbook /control/playbooks/site.yml
```


### Notes

* If configs/ansible.cfg exists, it is used; otherwise the image default /etc/ansible/ansible.cfg is used.

* ssh/authorized_keys (host) is mounted to the ansible user for SSH access.

* The ansible user exists inside the container; add more users only if you extend the entrypoint.

* ```PermitRootLogin no```, key-only auth via mounted ```ssh/authorized_keys```.
