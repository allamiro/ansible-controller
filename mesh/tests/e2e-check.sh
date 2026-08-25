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
# Fail CLOSED: the probe always exits 0 and reports OPEN/CLOSED on stdout, so a
# docker/exec-level error (container down, shell missing) is a FAIL, not a
# silent pass. `if docker exec ...; then fail; fi` alone would map any
# operational error onto the security property holding.
probe=$(docker exec mesh-e2e-orchestrator bash -c \
  'timeout 3 bash -c "exec 6<>/dev/tcp/mesh-e2e-target/22" 2>/dev/null && echo OPEN || echo CLOSED') \
  || fail "could not run the route probe on the orchestrator"
case "$probe" in
  CLOSED) pass "orchestrator cannot reach mesh-e2e-target:22" ;;
  OPEN)   fail "orchestrator CAN reach the target — topology broken" ;;
  *)      fail "route probe returned '$probe'" ;;
esac

echo "== 5. the execution node CAN reach the target =="
docker exec mesh-e2e-node-a bash -c 'timeout 3 bash -c "exec 6<>/dev/tcp/mesh-e2e-target/22"' \
  && pass "execution node reaches mesh-e2e-target:22" \
  || fail "execution node cannot reach mesh-e2e-target:22"

echo "== 6. node receptor runs unprivileged =="
uid=$(docker exec mesh-e2e-node-a sh -c 'awk "/^Uid:/{print \$2}" /proc/1/status')
[ "$uid" = "1000" ] && pass "receptor is PID 1 as uid 1000" || fail "receptor uid=$uid"

echo "== 7. no sshd on the execution node =="
# Same fail-closed shape — and no pgrep: the node image ships no procps, so a
# pgrep-based check "passed" by the tool being absent. /proc needs nothing.
sshd_count=$(docker exec mesh-e2e-node-a sh -c \
  'c=0; for f in /proc/[0-9]*/comm; do [ "$(cat "$f" 2>/dev/null)" = sshd ] && c=$((c+1)); done; echo "count=$c"') \
  || fail "could not enumerate processes on the node"
case "$sshd_count" in
  count=0) pass "no sshd on the execution node" ;;
  count=*) fail "sshd is running on the execution node (${sshd_count#count=} found)" ;;
  *)       fail "process probe returned '$sshd_count'" ;;
esac

echo "== 8. node receptor is the patched CVE-clean build =="
v=$(docker exec mesh-e2e-node-a receptor --version)
[ "$v" = "1.6.7" ] && pass "receptor 1.6.7 (patched module set, asserted at build)" \
  || fail "unexpected receptor version: $v"

echo "== 9. distributed playbook run succeeds (transmit -> submit -> worker -> process) =="
docker exec mesh-e2e-orchestrator bash -euc '
  printf "mesh-e2e-target ansible_user=ansible ansible_ssh_common_args=\"-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null\"\n" > /tmp/e2e-inv
' || fail "could not write inventory on the orchestrator"
run_out=$(docker exec mesh-e2e-orchestrator /usr/local/mesh/bin/mesh-run \
    --node exec-e2e-a --playbook /mesh-playbooks/mesh-ping.yml \
    --inventory /tmp/e2e-inv --ssh-key /e2e-ssh/id_ed25519 2>&1) \
  && pass "mesh-run rc=0 across the mesh" \
  || fail "mesh-run failed: $(tail -3 <<<"$run_out")"

echo "== 10. the play EXECUTED on the node, not on the controller =="
node_host=$(docker exec mesh-e2e-node-a hostname)
orch_host=$(docker exec mesh-e2e-orchestrator hostname)
grep -q "EXECUTED-ON=${node_host} " <<<"$run_out" \
  && pass "EXECUTED-ON=${node_host} (the execution node)" \
  || fail "play did not report executing on the node (${node_host}); output: $(grep -o "EXECUTED-ON=[^ ]*" <<<"$run_out" | head -1)"
grep -q "EXECUTED-ON=${orch_host} " <<<"$run_out" \
  && fail "play executed on the ORCHESTRATOR (${orch_host})" \
  || pass "and not on the orchestrator (${orch_host})"

echo "== 11. artifacts returned to the controller side =="
job_id=$(grep -o "job=[0-9a-f-]*" <<<"$run_out" | cut -d= -f2)
[ -n "$job_id" ] || fail "no job id in mesh-run output"
art=$(docker exec mesh-e2e-orchestrator bash -euc "
  pdd=/var/lib/mesh/jobs/$job_id
  rc=\$(find \$pdd/artifacts -name rc -type f -exec cat {} \; | head -1)
  ev=\$(find \$pdd/artifacts -path \"*job_events*\" -name \"*.json\" | wc -l)
  so=\$(find \$pdd/artifacts -name stdout -type f | wc -l)
  echo \"rc=\$rc events=\$ev stdout=\$so\"") \
  || fail "could not inspect artifacts for job $job_id"
case "$art" in
  "rc=0 events="*) [ "${art#*stdout=}" != 0 ] && pass "artifacts complete ($art)" || fail "no stdout artifact ($art)";;
  *) fail "unexpected artifacts state: $art";;
esac

echo "== 12. per-job meta.json records the lifecycle =="
meta=$(docker exec mesh-e2e-orchestrator cat /var/lib/mesh/jobs/$job_id/meta.json 2>/dev/null) \
  || fail "meta.json missing for job $job_id"
grep -q '"status":"succeeded"' <<<"$meta" && grep -q '"node":"exec-e2e-a"' <<<"$meta" \
  && pass "meta.json: succeeded on exec-e2e-a" \
  || fail "meta.json wrong: $meta"

echo "== 13. a failing playbook propagates its real rc back =="
if docker exec mesh-e2e-orchestrator /usr/local/mesh/bin/mesh-run \
    --node exec-e2e-a --playbook /mesh-playbooks/mesh-fail.yml \
    --inventory /tmp/e2e-inv --ssh-key /e2e-ssh/id_ed25519 >/dev/null 2>&1; then
  fail "mesh-run returned 0 for a playbook that must fail"
else
  pass "failing playbook returned nonzero rc across the mesh"
fi

echo "All mesh e2e regression checks passed."
