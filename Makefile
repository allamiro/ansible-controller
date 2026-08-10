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

# Install roles and collections declared in configs/requirements.yml
# (-i without -t so the targets also work from scripts/CI, not just a terminal)
galaxy:
	docker exec -i ansible-controller ansible-galaxy install -r /configs/requirements.yml --roles-path /configs/.galaxy/roles
	docker exec -i ansible-controller ansible-galaxy collection install -r /configs/requirements.yml -p /configs/.galaxy/collections

# Force re-install / update Galaxy content to the versions in requirements.yml
galaxy-force:
	docker exec -i ansible-controller ansible-galaxy install -r /configs/requirements.yml --roles-path /configs/.galaxy/roles --force
	docker exec -i ansible-controller ansible-galaxy collection install -r /configs/requirements.yml -p /configs/.galaxy/collections --force

logs:
	docker logs -f ansible-controller
