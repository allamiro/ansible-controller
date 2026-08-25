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

# ---- distributed execution mesh (mesh/ — see mesh/RUNBOOK.md) ----
# The control plane: controller (orchestrator image) + both receptor ingress
# sidecars. Needs issued identities under mesh/secrets/ first; the runbook
# walks the full setup. All mesh targets use -i without -t so they also work
# from scripts and CI.
mesh-up:
	docker compose -f docker-compose.yml -f mesh/compose.mesh.yml --profile mesh up -d

mesh-down:
	docker compose -f docker-compose.yml -f mesh/compose.mesh.yml --profile mesh down

# Mesh view from BOTH ingresses; either may be down (that is what Tier-1
# redundancy is for), so a single dead sidecar must not fail the status.
mesh-status:
	-docker exec -i ansible-controller receptorctl --socket /run/receptor/receptor.sock status
	-docker exec -i ansible-controller receptorctl --socket /run/receptor/receptor-b.sock status

# Reach one node over the mesh:  make mesh-ping NODE=exec-dmz-a
mesh-ping:
	@test -n "$(NODE)" || { echo "usage: make mesh-ping NODE=<node-id>"; exit 2; }
	docker exec -i ansible-controller receptorctl --socket /run/receptor/receptor.sock ping $(NODE)

# Dispatch a playbook over the mesh. Exactly one of NODE / POOL / ZONE:
#   make mesh-run NODE=exec-dmz-a PLAYBOOK=site.yml INVENTORY=inventory/dmz.ini
#   make mesh-run ZONE=dmz PLAYBOOK=site.yml INVENTORY=inventory/dmz.ini SSH_KEY=/home/ansible/.ssh/id_ed25519
# PLAYBOOK is relative to /configs/playbooks, INVENTORY to /configs (same
# conventions as `make run`); SSH_KEY is a container path.
MESH_INVENTORY ?= inventory/hosts.ini
mesh-run:
	docker exec -i ansible-controller /usr/local/mesh/bin/mesh-run \
		$(if $(NODE),--node $(NODE),) $(if $(POOL),--pool $(POOL),) $(if $(ZONE),--zone $(ZONE),) \
		--playbook /configs/playbooks/$(PLAYBOOK) \
		--inventory /configs/$(or $(INVENTORY),$(MESH_INVENTORY)) \
		$(if $(SSH_KEY),--ssh-key $(SSH_KEY),)
