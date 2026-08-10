IMAGE ?= ansible-controller:latest
PLAYBOOK ?= site.yml

build:
	docker compose build

up:
	docker compose up -d

down:
	docker compose down

shell:
	docker exec -it ansible-controller bash

# Drop into the container (alias kept for backward compat)
sh: shell

run:
	docker exec -it ansible-controller ansible-playbook /configs/playbooks/$(PLAYBOOK)

# Install roles and collections declared in configs/requirements.yml.
# (-i without -t so the targets also work from scripts/CI, not just a terminal.)
# flock shares a lock with the container's startup auto-install, so this both
# avoids racing it and blocks until any in-flight startup install completes —
# run `make galaxy` after `make up` to guarantee content is ready.
galaxy:
	docker exec -i ansible-controller sh -c 'mkdir -p /configs/.galaxy && flock /configs/.galaxy/.install.lock ansible-galaxy install -r /configs/requirements.yml --roles-path /configs/.galaxy/roles'
	docker exec -i ansible-controller sh -c 'mkdir -p /configs/.galaxy && flock /configs/.galaxy/.install.lock ansible-galaxy collection install -r /configs/requirements.yml -p /configs/.galaxy/collections'

# Install extra Python packages declared in configs/pip-requirements.txt.
# Shares a lock with the startup auto-install, so it also waits for an
# in-flight startup install to finish.
pip:
	docker exec -i ansible-controller sh -c 'flock /configs/.pip-install.lock pip3 install --no-cache-dir --break-system-packages -r /configs/pip-requirements.txt'

# Force re-install / update Galaxy content to the versions in requirements.yml
galaxy-force:
	docker exec -i ansible-controller sh -c 'mkdir -p /configs/.galaxy && flock /configs/.galaxy/.install.lock ansible-galaxy install -r /configs/requirements.yml --roles-path /configs/.galaxy/roles --force'
	docker exec -i ansible-controller sh -c 'mkdir -p /configs/.galaxy && flock /configs/.galaxy/.install.lock ansible-galaxy collection install -r /configs/requirements.yml -p /configs/.galaxy/collections --force'

# Lint playbooks with ansible-lint (baked into the image).
# Runs from /configs/playbooks so a .ansible-lint config there is discovered.
# ANSIBLE_CONFIG: docker exec doesn't inherit the entrypoint's export, and the
# custom roles/collections paths are needed for resolution during linting.
# XDG_CACHE_HOME: the playbooks mount is read-only; keep caches writable.
lint:
	docker exec -i -e ANSIBLE_CONFIG=/configs/ansible.cfg -e XDG_CACHE_HOME=/tmp/.cache ansible-controller sh -c 'cd /configs/playbooks && ansible-lint'

logs:
	docker logs -f ansible-controller
