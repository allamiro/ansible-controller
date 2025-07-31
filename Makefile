IMAGE ?= ansible-controller:latest

build:
\tdocker compose build

up:
\tdocker compose up -d

down:
\tdocker compose down

sh:
\tdocker exec -it ansible-controller bash

logs:
\tdocker logs -f ansible-controller
