# syntax=docker/dockerfile:1
#
# Mesh images — built SEPARATELY from the controller and never by the default
# pipeline. They start FROM the finished controller image, so they inherit its
# exact runtime and CVE remediation (patch-pip-vendor.py, pebble removal) with
# zero dependency drift and zero change to the controller build. See
# mesh/README.md for the full design.
#
# Build the orchestrator (control-plane dispatcher) image:
#   docker build -f docker/mesh/Dockerfile --target orchestrator \
#     --build-arg BASE=ghcr.io/allamiro/ansible-controller:latest \
#     -t ansible-orchestrator:dev .
#
# BASE must be a controller image built from docker/Dockerfile; pin it to a digest
# for real deployments. The execution-node target is added in a follow-up PR
# (mesh plan Phase 4) so receptor's Go-binary CVE surface is reviewed on its own.
ARG BASE=ghcr.io/allamiro/ansible-controller:latest

# ---- orchestrator: the control-plane image that DISPATCHES work ----
# = controller + ansible-runner (transmit/process) + receptorctl (talk to the
# receptor control socket over its Unix socket). It keeps the controller's
# sshd/entrypoint unchanged, so operators run `make mesh-run` the same way they
# run `make run` today.
FROM ${BASE} AS orchestrator

# Pinned; pure-Python so no compiler/toolchain is pulled in. --break-system-packages
# / --ignore-installed mirror the base image's pip usage (PEP 668, apt-owned deps).
RUN pip3 install --no-cache-dir --break-system-packages --ignore-installed \
      "ansible-runner==2.4.3" \
      "receptorctl==1.6.7" \
 && ansible-runner --version \
 && receptorctl --help >/dev/null
