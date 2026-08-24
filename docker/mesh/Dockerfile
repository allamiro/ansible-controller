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
RUN set -eux; \
    pip3 freeze --all | grep -E '^[A-Za-z0-9._-]+==' | LC_ALL=C sort > /tmp/base-pins.txt; \
    test -s /tmp/base-pins.txt; \
    grep -vi '^click==' /tmp/base-pins.txt > /tmp/constraints.txt; \
    pip3 install --no-cache-dir --break-system-packages \
      -c /tmp/constraints.txt \
      "ansible-runner==2.4.3" \
      "receptorctl==1.6.7" \
      "click==8.3.3"; \
    pip3 freeze --all | grep -E '^[A-Za-z0-9._-]+==' | LC_ALL=C sort > /tmp/mesh-pins.txt; \
    drift="$(LC_ALL=C comm -23 /tmp/base-pins.txt /tmp/mesh-pins.txt | grep -vi '^click==' || true)"; \
    if [ -n "$drift" ]; then \
      echo "ERROR: the orchestrator layer changed controller dependencies:" >&2; \
      echo "$drift" >&2; \
      exit 1; \
    fi; \
    rm -f /tmp/base-pins.txt /tmp/constraints.txt /tmp/mesh-pins.txt; \
    pip3 check; \
    ansible --version; \
    ansible-runner --version; \
    receptorctl --help >/dev/null
