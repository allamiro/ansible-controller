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
ev_n=$(sed -n 's/.*events=\([0-9]*\).*/\1/p' <<<"$art")
so_n=$(sed -n 's/.*stdout=\([0-9]*\).*/\1/p' <<<"$art")
case "$art" in "rc=0 "*) ;; *) fail "unexpected artifacts state: $art";; esac
[ -n "$ev_n" ] && [ "$ev_n" -gt 0 ] || fail "no job_events came back ($art)"
[ -n "$so_n" ] && [ "$so_n" -gt 0 ] || fail "no stdout artifact ($art)"
pass "artifacts complete ($art)"

echo "== 12. per-job meta.json records the lifecycle =="
meta_verdict=$(docker exec mesh-e2e-orchestrator python3 -c "
import json
d = json.load(open('/var/lib/mesh/jobs/$job_id/meta.json'))
print('ok' if d.get('status') == 'succeeded' and d.get('node') == 'exec-e2e-a' else 'bad: ' + json.dumps(d))
" 2>&1) || fail "meta.json unreadable for job $job_id: $(tail -1 <<<"$meta_verdict")"
[ "$meta_verdict" = ok ] \
  && pass "meta.json parses: succeeded on exec-e2e-a" \
  || fail "meta.json wrong — $meta_verdict"

echo "== 13. a failing playbook propagates its real rc back =="
# Fail CLOSED: a probe-level error (container down, mesh-run's own die()) must
# not impersonate rc propagation. Proof requires mesh-run's completion line —
# printed only after a full round-trip — carrying a nonzero artifact rc.
fail_out=$(docker exec mesh-e2e-orchestrator /usr/local/mesh/bin/mesh-run \
    --node exec-e2e-a --playbook /mesh-playbooks/mesh-fail.yml \
    --inventory /tmp/e2e-inv --ssh-key /e2e-ssh/id_ed25519 2>&1) && \
  fail "mesh-run returned 0 for a playbook that must fail"
fail_rc=$(grep -o "mesh-run: job=.* rc=[0-9]*" <<<"$fail_out" | sed -n "s/.*rc=\([0-9]*\).*/\1/p" || true)
if [ -n "$fail_rc" ] && [ "$fail_rc" -ne 0 ]; then
  pass "failing playbook completed the round-trip with rc=$fail_rc"
else
  fail "no completed round-trip with nonzero rc; output tail: $(tail -2 <<<"$fail_out")"
fi

echo "== 14. mTLS is mandatory and correctly shaped (§9.3 config assertions) =="
for c in mesh-e2e-receptor mesh-e2e-receptor-b mesh-e2e-node-a; do
  cfg=$(docker exec "$c" cat /etc/receptor/receptor.conf 2>/dev/null \
        || docker exec "$c" cat /run/receptor/receptor.conf 2>/dev/null) \
    || fail "cannot read receptor config on $c"
  # match ACTIVE keys only — the configs' comments legitimately mention these
  # options by name to document that they are deliberately absent
  active=$(grep -vE '^[[:space:]]*#' <<<"$cfg")
  grep -qE "tls-(server|client):" <<<"$active" || fail "$c has no TLS config"
  grep -qE "^[[:space:]]*insecureskipverify[[:space:]]*:" <<<"$active" && fail "$c config sets insecureskipverify"
  grep -qE "^[[:space:]]*skipreceptornamescheck[[:space:]]*:" <<<"$active" && fail "$c config sets skipreceptornamescheck"
done
for ing in mesh-e2e-receptor mesh-e2e-receptor-b; do
  grep -q "requireclientcert: true" <<<"$(docker exec "$ing" cat /etc/receptor/receptor.conf)" \
    || fail "$ing does not require client certificates"
done
pass "TLS on every hop; BOTH ingresses require client certs; no insecure escapes"

# the compose network derives from the project name (e2e-up honours
# COMPOSE_PROJECT_NAME the same way for volume seeding)
E2E_NET="${COMPOSE_PROJECT_NAME:-mesh-e2e}_ctlnet"

# succeeds only when the rogue RAN THE WHOLE TIME yet never joined — a rogue
# that died instantly (bad mount, refused entrypoint) is a broken test setup,
# not a proven rejection, and must FAIL the check rather than fake a pass.
rogue_absent() { # container-name  status-pattern
  local tries=0
  while [ $tries -lt 5 ]; do
    docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null | grep -q true \
      || { echo "rogue $1 is not running — test setup broken, not a rejection" >&2; return 2; }
    st=$(docker exec mesh-e2e-receptor receptorctl --socket /run/receptor/receptor.sock status 2>/dev/null || true)
    grep -q "$2" <<<"$st" && return 1
    tries=$((tries+1)); sleep 2
  done
  return 0
}

echo "== 15. a node WITHOUT a certificate is rejected (§9.3) =="
docker run -d --rm --name mesh-e2e-rogue-plain --network "$E2E_NET" \
  -e RECEPTOR_NODE_ID=exec-rogue-plain -e RECEPTOR_PEERS=mesh-e2e-receptor:27199 \
  -e RECEPTOR_INSECURE_DEV=1 ansible-execution-node:e2e >/dev/null \
  || fail "could not start the plaintext rogue"
rogue_absent mesh-e2e-rogue-plain exec-rogue-plain && pass "plaintext (certless) node never joined the mesh" \
  || { docker rm -f mesh-e2e-rogue-plain >/dev/null 2>&1; fail "certless node JOINED the mesh"; }
docker rm -f mesh-e2e-rogue-plain >/dev/null 2>&1 || true

echo "== 16. a certificate from an UNKNOWN CA is rejected (§9.3) =="
docker run -d --rm --name mesh-e2e-rogue-ca --network "$E2E_NET" \
  -v "$PWD/mesh/tests/.e2e-pki/rogue/issued/exec-rogue:/e2e-tls:ro" \
  -e RECEPTOR_NODE_ID=exec-rogue -e RECEPTOR_PEERS=mesh-e2e-receptor:27199 \
  -e RECEPTOR_TLS_CERT=/e2e-tls/tls.crt -e RECEPTOR_TLS_KEY=/e2e-tls/tls.key \
  -e RECEPTOR_TLS_CA=/e2e-tls/ca.crt ansible-execution-node:e2e >/dev/null \
  || fail "could not start the unknown-CA rogue"
rogue_absent mesh-e2e-rogue-ca "^exec-rogue " && pass "unknown-CA node never joined the mesh" \
  || { docker rm -f mesh-e2e-rogue-ca >/dev/null 2>&1; fail "unknown-CA node JOINED the mesh"; }
docker rm -f mesh-e2e-rogue-ca >/dev/null 2>&1 || true

echo "== 17. node id ≠ certificate identity is rejected (§9.3) =="
# A VALID mesh cert (exec-e2e-a's) presented by a node CLAIMING to be someone
# else. Rejection here is even stronger than 15/16: receptor cross-checks its
# OWN node id against its OWN cert at startup and refuses to build a TLS client
# at all, so the container EXITS with an identity-mismatch error rather than
# running-but-not-joining. Assert exactly that — a clean exit or a different
# error would not prove the identity binding.
idlog=$(docker run --rm --network "$E2E_NET" \
  -v "$PWD/mesh/tests/.e2e-pki/issued/exec-e2e-a:/e2e-tls:ro" \
  -e RECEPTOR_NODE_ID=exec-imposter -e RECEPTOR_PEERS=mesh-e2e-receptor:27199 \
  -e RECEPTOR_TLS_CERT=/e2e-tls/tls.crt -e RECEPTOR_TLS_KEY=/e2e-tls/tls.key \
  -e RECEPTOR_TLS_CA=/e2e-tls/ca.crt ansible-execution-node:e2e 2>&1) && \
  fail "identity-mismatch node started successfully (must be rejected)"
grep -qi "exec-imposter not found in certificate" <<<"$idlog" \
  && pass "valid cert with the WRONG node id refused at startup (identity binding enforced)" \
  || fail "identity-mismatch rejection not by identity binding; got: $(tail -1 <<<"$idlog")"

echo "== 18. Tier-1 ingress failover (§9.7): stop sidecar A, dispatch through B =="
docker stop mesh-e2e-receptor >/dev/null || fail "could not stop sidecar A"
t1_out=$(docker exec mesh-e2e-orchestrator /usr/local/mesh/bin/mesh-run \
    --node exec-e2e-a --playbook /mesh-playbooks/mesh-ping.yml \
    --inventory /tmp/e2e-inv --ssh-key /e2e-ssh/id_ed25519 \
    --socket /run/receptor/receptor.sock,/run/receptor/receptor-b.sock 2>&1) \
  && grep -q "rc=0" <<<"$t1_out" \
  && pass "dispatch succeeded through sidecar B with A down" \
  || { docker start mesh-e2e-receptor >/dev/null 2>&1; fail "dispatch failed with A down: $(tail -2 <<<"$t1_out")"; }
docker start mesh-e2e-receptor >/dev/null || fail "could not restart sidecar A"
# restart must mean RECOVERED: A's receptor answering and the node visible
# again through A — `docker start` returning 0 proves neither.
deadline=$((SECONDS + 60)); recovered=0
while [ $SECONDS -lt $deadline ]; do
  st=$(docker exec mesh-e2e-receptor receptorctl --socket /run/receptor/receptor.sock status 2>/dev/null || true)
  if grep -q "exec-e2e-a" <<<"$st"; then recovered=1; break; fi
  sleep 3
done
[ "$recovered" = 1 ] && pass "sidecar A recovered: answering, node re-peered" \
  || fail "sidecar A restarted but never recovered the node within 60s"

echo "All mesh e2e regression checks passed."
