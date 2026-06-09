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
	docker exec -it ansible-controller ansible-playbook /configs/$(PLAYBOOK)

logs:
	docker logs -f ansible-controller
