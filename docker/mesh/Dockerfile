# syntax=docker/dockerfile:1
#
# Mesh images — built SEPARATELY from the controller and never by the default
# pipeline. They start FROM the finished controller image, so they inherit its
# exact runtime and CVE remediation (patch-pip-vendor.py, pebble removal) with
# zero change to the controller build. See mesh/README.md for the full design.
#
# Build the orchestrator (control-plane dispatcher) image:
#   docker build -f docker/mesh/Dockerfile --target orchestrator \
#     --build-arg BASE=ghcr.io/allamiro/ansible-controller@sha256:<digest> \
#     -t ansible-orchestrator:dev .
#
# BASE is REQUIRED and deliberately has no default. It must name a controller
# image built from docker/Dockerfile, pinned to an immutable digest: a tag is a
# mutable pointer, so it would silently re-base the image on whatever controller
# it points at come build time — the very drift this design exists to prevent.
# With no default the build fails closed ("base name (${BASE}) should not be
# blank"), and the guard in the stage below rejects a BASE that is not a digest.
#
# A controller image that was just built locally and never pushed has no digest
# to name; such builds opt out explicitly and are warned that the result is not
# reproducible:
#   --build-arg ALLOW_MUTABLE_BASE=1
#
# The execution-node target is added in a follow-up PR (mesh plan Phase 4) so
# receptor's Go-binary CVE surface is reviewed on its own.
ARG BASE

# ---- orchestrator: the control-plane image that DISPATCHES work ----
# = controller + ansible-runner (transmit/process) + receptorctl (talk to the
# receptor control socket over its Unix socket). It keeps the controller's
# sshd/entrypoint unchanged, so operators run `make mesh-run` the same way they
# run `make run` today.
FROM ${BASE} AS orchestrator

# Re-declared so the value is readable inside the stage (a pre-FROM ARG is not).
ARG BASE
# Enforce the immutability promise above rather than only documenting it: a tag —
# `:latest` or any other — can be repointed between builds, so BASE must name a
# digest. Local builds against a controller that was just built and never pushed
# have no digest to name, so they opt out explicitly and get a warning instead:
#   --build-arg ALLOW_MUTABLE_BASE=1
ARG ALLOW_MUTABLE_BASE=0
RUN set -eu; \
    case "${BASE}" in \
      *@sha256:*) ;; \
      *) if [ "${ALLOW_MUTABLE_BASE}" != "1" ]; then \
           echo "ERROR: BASE='${BASE}' is not digest-pinned." >&2; \
           echo "       Pass a controller image as repo@sha256:<digest> so the mesh" >&2; \
           echo "       image cannot be silently re-based between builds, or set" >&2; \
           echo "       --build-arg ALLOW_MUTABLE_BASE=1 for a local build." >&2; \
           exit 1; \
         fi; \
         echo "WARNING: BASE='${BASE}' is a mutable reference; this image is not reproducible." >&2 ;; \
    esac

# bash with pipefail: the pins snapshot below is built through a pipe, and under
# the default /bin/sh (dash, no pipefail) a failing `pip3 freeze` would be masked
# by the succeeding `sort` — leaving an empty snapshot that the no-drift assertion
# would then "pass" vacuously. Only shell-form instructions are affected; the
# controller's exec-form CMD/ENTRYPOINT are untouched.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Pinned; pure-Python, so no compiler or toolchain is pulled in.
# --break-system-packages: required by PEP 668, as in the controller layer.
#
# The controller's own pip pins are captured first and fed back as CONSTRAINTS, so
# resolving these packages may ADD dependencies but cannot upgrade or replace one
# the controller already ships. That makes "inherits the controller's runtime" a
# property the build ENFORCES rather than one the resolver happens to grant: the
# freeze/comm assertion below fails the build if any controller pin moved.
#
# click is the single, deliberate exception. receptorctl 1.6.7 — the newest
# release — caps click at <8.4.0 while the controller ships 8.4.2, so the
# orchestrator cannot hold the controller's version. It is pinned explicitly (not
# left to the resolver) and exempted from the assertion. The downgrade is safe and
# narrow: the controller's only click consumer is black (click>=8.0.0, pulled in
# by ansible-lint), which 8.3.3 satisfies, and ansible-core does not use click at
# all. `pip3 check` below re-verifies the whole graph is consistent afterwards.
# Revisit the pin when a receptorctl release lifts the cap.
#
# --ignore-installed is deliberately NOT used here. The controller layer needs it
# because apt-owned packages carry no pip RECORD, so pip cannot uninstall them;
# everything this layer resolves against was installed by pip and has a RECORD, so
# pip can reuse it in place instead of refetching it.
# The exact set this layer is allowed to add, transitive dependencies included.
# Constraints stop the controller's own pins from moving, but they say nothing
# about packages the controller does not have: those would resolve to whatever is
# newest at build time, so a digest-pinned BASE would still produce a different
# image on a later rebuild. Pinning the full closure — and asserting the closure
# is exactly this — makes the orchestrator reproducible for a given BASE.
# Regenerate after changing a pin above: `comm -13` of the pins before/after.
COPY docker/mesh/orchestrator-added.txt /tmp/expected-added.txt

RUN set -eux; \
    pip3 freeze --all | grep -E '^[A-Za-z0-9._-]+==' | LC_ALL=C sort > /tmp/base-pins.txt; \
    test -s /tmp/base-pins.txt; \
    grep -vi '^click==' /tmp/base-pins.txt > /tmp/constraints.txt; \
    pip3 install --no-cache-dir --break-system-packages \
      -c /tmp/constraints.txt \
      "ansible-runner==2.4.3" \
      "receptorctl==1.6.7" \
      "click==8.3.3" \
      "lockfile==0.12.2" \
      "pexpect==4.9.0" \
      "ptyprocess==0.7.0" \
      "python-daemon==3.1.2" \
      "python-dateutil==2.9.0.post0" \
      "six==1.17.0"; \
    pip3 freeze --all | grep -E '^[A-Za-z0-9._-]+==' | LC_ALL=C sort > /tmp/mesh-pins.txt; \
    drift="$(LC_ALL=C comm -23 /tmp/base-pins.txt /tmp/mesh-pins.txt | grep -vi '^click==' || true)"; \
    if [ -n "$drift" ]; then \
      echo "ERROR: the orchestrator layer changed controller dependencies:" >&2; \
      echo "$drift" >&2; \
      exit 1; \
    fi; \
    LC_ALL=C comm -13 /tmp/base-pins.txt /tmp/mesh-pins.txt > /tmp/added.txt; \
    if ! LC_ALL=C diff -u /tmp/expected-added.txt /tmp/added.txt; then \
      echo "ERROR: the packages added by this layer are not the pinned set above." >&2; \
      echo "       A dependency appeared, vanished, or resolved to another version;" >&2; \
      echo "       pin it explicitly (or drop the stale pin) so the image stays" >&2; \
      echo "       reproducible, then rebuild." >&2; \
      exit 1; \
    fi; \
    rm -f /tmp/base-pins.txt /tmp/constraints.txt /tmp/mesh-pins.txt \
          /tmp/added.txt /tmp/expected-added.txt; \
    pip3 check; \
    ansible --version; \
    ansible-runner --version; \
    receptorctl --help >/dev/null

# Record what this image was actually built on, so a running orchestrator can be
# traced back to its controller even when BASE was a mutable reference.
LABEL org.opencontainers.image.base.name="${BASE}"
LABEL org.opencontainers.image.title="Ansible Mesh Orchestrator"

# ---- receptor, built from source with patched Go module deps ----
# Upstream's receptor v1.6.7 binary (quay.io/ansible/receptor) carries 11
# fixable HIGH CVEs from stale golang.org/x/crypto v0.51.0, x/net v0.55.0 and
# x/text v0.37.0, and no upstream release has shipped the fixes yet. The repo's
# CVE gate (0 fixable CRITICAL/HIGH) applies to every mesh image, so — same
# precedent as the controller's pip-vendor patch — the binary is rebuilt from
# the EXACT v1.6.7 tag commit with only those three modules bumped to their
# fixed releases. Drop this stage and return to COPYing upstream's binary once
# a receptor release ships with patched deps. (The Phase 3 sidecar still runs
# upstream's image; switching it to this build is a follow-up once this image
# is published, mesh plan Phase 11.)
FROM golang:1.25-trixie@sha256:2c4c60ef415fbfa5e90300722293bef36c5e63fae17570ce18f580af933dbd73 AS receptor-build
# Tag commit pinned, not the tag name — tags can be moved, commits cannot.
RUN git clone --filter=blob:none https://github.com/ansible/receptor /src  && cd /src  && git checkout -q d0798033b600f6f6ad0709e99dc7d58379a22bc6  && go get golang.org/x/crypto@v0.53.0 golang.org/x/net@v0.56.0 golang.org/x/text@v0.39.0  && go mod tidy  && CGO_ENABLED=0 go build -trimpath       -ldflags "-s -w -X github.com/ansible/receptor/internal/version.Version=1.6.7"       -o /receptor ./cmd/receptor-cl  && test "$(/receptor --version)" = "1.6.7"

# ---- execution-node: the image that RUNS work on a zone's network ----
# = controller + ansible-runner (worker) + receptor (the mesh peer itself).
#
# Built FROM the orchestrator stage rather than ${BASE} (a deliberate deviation
# from mesh/README.md §5): the orchestrator layer already carries the pinned
# ansible-runner/receptorctl closure AND the build-time assertions that prove the
# controller's runtime survived intact. Repeating that machinery here would be a
# second copy to drift; inheriting it keeps one source of truth. Contents are
# exactly the plan's "controller + receptor + ansible-runner" — plus receptorctl,
# which the HEALTHCHECK needs anyway.
FROM orchestrator AS execution-node

# Static CGO_ENABLED=0 binary from the patched source build above — same 1.6.7
# code, CVE-clean module set, no libc coupling to the Ubuntu base.
COPY --from=receptor-build /receptor /usr/local/bin/receptor

COPY docker/mesh/node-entrypoint.sh /usr/local/bin/node-entrypoint.sh

# The node runs receptor, NOT sshd: nothing dials INTO an execution node — it
# dials OUT to the controller's ingress (tcp-peer) and receives work over that
# receptor connection. Everything below runs as the unprivileged ansible user
# (uid 1000, created by the controller layer); receptor is PID 1 via exec, and
# the inherited sshd entrypoint is simply never started.
RUN chmod 755 /usr/local/bin/node-entrypoint.sh \
 && receptor --version \
 && mkdir -p /run/receptor /var/lib/receptor \
 && chown ansible:ansible /run/receptor /var/lib/receptor
USER ansible

# Override the controller's port-22 HEALTHCHECK: there is no sshd here. Healthy
# means receptor is up AND answering on its local control socket.
HEALTHCHECK --interval=30s --timeout=5s --retries=3 --start-period=10s \
  CMD ["receptorctl", "--socket", "/run/receptor/receptor.sock", "status"]

ENTRYPOINT ["/usr/local/bin/node-entrypoint.sh"]
