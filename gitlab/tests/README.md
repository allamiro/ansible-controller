# Isolated GitLab CE verification

This suite uses Compose project **gitlab-audit**. It does not reuse the root
controller, `gitlab-lab`, or `mesh-e2e` volumes. See
[VERIFICATION.md](../VERIFICATION.md) for results and remaining gaps.

## Prerequisites

Docker with Compose, Python 3, OpenSSL, and these local runtime images:
`ansible-controller:e2e`, `ansible-orchestrator:e2e`,
`ansible-execution-node:e2e`. The latter two can be built from a chosen
controller image with `docker/mesh/Dockerfile`, targets `orchestrator` and
`execution-node`, `--build-arg BASE=<image>` and, for a local development tag,
`--build-arg ALLOW_MUTABLE_BASE=1`. Do not run the existing `e2e-up.sh` just to
build these: it also manages a different lab.

The Compose file pins GitLab CE 19.3.1 and Runner 19.3.1, the latest stable
version verified on 2026-09-08. Recheck GitLab's official patch release list
before later use; a floating `latest` tag would make evidence irreproducible.
Allow several GB of spare RAM and disk for a second GitLab instance.

## Run from repository root

Run the isolated command regressions without Docker or a GitLab instance
(Python 3, PyYAML, Git, Bash, jq, and standard Linux command-line tools):

```bash
python3 -m unittest discover -s gitlab/tests -p 'test_*.py' -v
```

The live integration sequence is:

```bash
python3 gitlab/tests/prepare.py
docker compose --env-file gitlab/tests/.state/lab.env -f gitlab/tests/compose.yml up -d --wait --wait-timeout 900
python3 gitlab/tests/bootstrap.py
python3 gitlab/tests/test_ctl_run.py
python3 gitlab/tests/verify.py
python3 gitlab/tests/boundaries.py
python3 gitlab/tests/extended.py
python3 gitlab/tests/lifecycle.py
python3 gitlab/tests/governance.py
python3 gitlab/tests/recovery.py
python3 gitlab/tests/ci_acceptance.py
```

`ci_acceptance.py` installs the current reference pipeline into the dedicated
audit project. It verifies manual release, successful and failed mesh artifact
downloads, replay of both results on GitLab job Retry, Developer denial,
Maintainer release/download access, and collection of the original UUID.
It changes that fixture's playbooks and pipeline, so run it last. Evidence is
saved privately as `.state/ci-acceptance.json`. Runner job containers use the
fixture's read-only `fips0` mount for the same disposable FIPS-host workaround
as GitLab; this fixture makes no FIPS compliance claim.

Bootstrap is deliberately one-shot: `bootstrap.started` records the first
attempt before API mutations. A partial attempt refuses automatic resume; inspect
its evidence, then reset both the disposable stack and `.state` using the reset
procedure below. A completed bootstrap (`bootstrap.done`) is a no-op on rerun.

Run the integration scripts sequentially: some intentionally stop their own
node/ingress or interrupt their own dispatcher. `lifecycle.py` and
`governance.py` create named disposable GitLab resources and are one-shot
scenarios, not general-purpose idempotent installers. They fail on conflicting
existing fixtures; inspect saved state before retrying an interrupted setup.
`verify.py` appends new pipeline evidence when rerun. Assertions and expected
failures are recorded separately from successful deployment jobs.

`.state` is gitignored and contains disposable credentials and certificates.
Raw job traces are private files there. Do not commit or publish that directory.
The bootstrap root PAT expires after two days; execution uses a separate
read-only repository deploy token, Runner authentication token, ephemeral CI
job token, and an SSH deployment key. The root password is in `.state/lab.env`.

## Inspect and stop

GitLab's lab HTTP UI is published only at `127.0.0.1:18929`. Its configured
external URL is `http://gitlab.audit.local:8929`, so generated links assume lab
DNS/ports. The HTTPS proxy is at `127.0.0.1:18443`; trust `.state/web-tls/ca.crt`
and use hostname `gitlab.audit.local` for that endpoint. The internal deployment
path uses `https://gitlab.audit.local:443`. This intentional split lets tests
exercise HTTPS and lab HTTP against one instance; it is not a production URL
configuration. Browsers need an appropriate local host mapping or proxy setup.

```bash
docker compose --env-file gitlab/tests/.state/lab.env -f gitlab/tests/compose.yml ps
docker compose --env-file gitlab/tests/.state/lab.env -f gitlab/tests/compose.yml stop
```

`stop` retains results and credentials for inspection. For an intentional full
reset, remove only this Compose project's volumes with `down -v`, then remove
its `.state` directory before preparing again. Do not delete state while keeping
GitLab data volumes: the bootstrap password/tokens would no longer match.

## Trust boundaries

GitLab belongs only to `gitnet`. Runner manager belongs to `control`; deployment
jobs use `control`, validation jobs use `gitnet`. GitLab cannot dial the
controller's control-network IP. The controller can reach the direct SSH target;
only the execution node belongs to the mesh target network. Both controllers
share fixture keys/inventory for this routing test, but have separate run-state
volumes: this is independent-controller operation, not HA or tenant isolation.

Only the Runner **manager** mounts the Docker socket. Docker job containers
receive no Docker socket, mesh socket, mesh state, target private key or signing
key. This still makes the manager and Docker host trusted infrastructure.
Do not cohost untrusted tenants on this disposable fixture.

The web CA key stays outside runtime mounts. The Receptor CA is separate;
nodes have issued identity keys and the public work-verification key, while
ingresses have their identity and work-signing material. In this single-host
fixture PKI creation is consolidated for convenience; it does not model an
offline production CA ceremony.

GitLab's FIPS flag is masked for this disposable lab. Some development images
also log FIPS-provider fallback. No FIPS compliance is claimed. HTTP disables
GitLab transport encryption only; SSH and mesh mTLS remain enabled.
