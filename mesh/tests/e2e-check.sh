#!/bin/bash
# Mesh e2e regression suite (mesh plan Phase 4 §9.1/§9.2 wiring properties).
# Each check is a property production depends on; exits non-zero on the first
# failure. Run by CI on every mesh change.
#
# NOTE: status outputs are captured into variables and grepped from there —
# piping `docker exec` straight into `grep -q` under pipefail fails spuriously,
# because grep exits at first match and the writer dies with SIGPIPE (141).
set -euo pipefail

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; exit 1; }

# The node redials with backoff; give a fresh environment up to 60s to converge.
deadline=$((SECONDS + 60))
while :; do
  ctl_status=$(docker exec mesh-e2e-receptor receptorctl --socket /run/receptor/receptor.sock status 2>/dev/null || true)
  grep -q 'exec-e2e-a' <<<"$ctl_status" && grep -q 'ansible-runner' <<<"$ctl_status" && break
  [ $SECONDS -lt $deadline ] || break
  sleep 3
done

echo "== 1. execution node joined the mesh =="
grep -q 'exec-e2e-a' <<<"$ctl_status" \
  && pass "exec-e2e-a visible from the control-plane receptor" \
  || fail "exec-e2e-a not in receptorctl status"

echo "== 2. node advertises the ansible-runner worktype =="
grep -q 'ansible-runner' <<<"$ctl_status" \
  && pass "worktype ansible-runner advertised" \
  || fail "worktype missing"

echo "== 3. orchestrator reaches the control socket over the shared volume =="
orch_status=$(docker exec -u root mesh-e2e-orchestrator receptorctl --socket /run/receptor/receptor.sock status 2>/dev/null || true)
grep -q 'exec-e2e-a' <<<"$orch_status" \
  && pass "orchestrator sees the node" \
  || fail "orchestrator cannot see the node"

echo "== 4. the control plane has NO route to the target (the load-bearing claim) =="
if docker exec mesh-e2e-orchestrator bash -c 'timeout 3 bash -c "exec 6<>/dev/tcp/mesh-e2e-target/22"' 2>/dev/null; then
  fail "orchestrator CAN reach the target — topology broken"
else
  pass "orchestrator cannot reach mesh-e2e-target:22"
fi

echo "== 5. the execution node CAN reach the target =="
docker exec mesh-e2e-node-a bash -c 'timeout 3 bash -c "exec 6<>/dev/tcp/mesh-e2e-target/22"' \
  && pass "execution node reaches mesh-e2e-target:22" \
  || fail "execution node cannot reach mesh-e2e-target:22"

echo "== 6. node receptor runs unprivileged =="
uid=$(docker exec mesh-e2e-node-a sh -c 'awk "/^Uid:/{print \$2}" /proc/1/status')
[ "$uid" = "1000" ] && pass "receptor is PID 1 as uid 1000" || fail "receptor uid=$uid"

echo "== 7. no sshd on the execution node =="
if docker exec mesh-e2e-node-a pgrep -x sshd >/dev/null 2>&1; then
  fail "sshd is running on the execution node"
else
  pass "no sshd on the execution node"
fi

echo "== 8. node receptor is the patched CVE-clean build =="
v=$(docker exec mesh-e2e-node-a receptor --version)
[ "$v" = "1.6.7" ] && pass "receptor 1.6.7 (patched module set, asserted at build)" \
  || fail "unexpected receptor version: $v"

echo "All mesh e2e regression checks passed."
