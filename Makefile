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

# Force re-install / update Galaxy content to the versions in requirements.yml
galaxy-force:
	docker exec -i ansible-controller sh -c 'mkdir -p /configs/.galaxy && flock /configs/.galaxy/.install.lock ansible-galaxy install -r /configs/requirements.yml --roles-path /configs/.galaxy/roles --force'
	docker exec -i ansible-controller sh -c 'mkdir -p /configs/.galaxy && flock /configs/.galaxy/.install.lock ansible-galaxy collection install -r /configs/requirements.yml -p /configs/.galaxy/collections --force'

logs:
	docker logs -f ansible-controller
