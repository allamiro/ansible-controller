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

# Check 17 bounds a host-side `docker run` with `timeout`. macOS ships no
# timeout(1), and the lab is advertised for any docker-capable host, so fall
# back to perl (present on every macOS and Linux box): the alarm survives the
# exec, and the bounded command dies on SIGALRM exactly as it would on
# timeout's SIGTERM — a nonzero status either way, which is all check 17 uses.
if ! command -v timeout >/dev/null 2>&1; then
  timeout() { perl -e 'alarm shift @ARGV; exec @ARGV' -- "$@"; }
fi

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
ra=0; rogue_absent mesh-e2e-rogue-plain exec-rogue-plain || ra=$?
docker rm -f mesh-e2e-rogue-plain >/dev/null 2>&1 || true
case $ra in
  0) pass "plaintext (certless) node never joined the mesh";;
  1) fail "certless node JOINED the mesh";;
  *) fail "certless-rogue test setup broken (rogue not running) — not a proven rejection";;
esac

echo "== 16. a client cert from an UNKNOWN CA is rejected by the ingress (§9.3) =="
# The rogue must TRUST the real mesh CA (so it accepts our server cert and the
# handshake reaches the point where the INGRESS evaluates the client cert),
# while presenting a client cert signed by the rogue CA. That isolates the
# property under test — requireclientcert + clientcas=mesh-CA rejecting an
# unknown client CA — rather than the rogue merely distrusting our server.
docker run -d --rm --name mesh-e2e-rogue-ca --network "$E2E_NET" \
  -v "$PWD/mesh/tests/.e2e-pki/rogue/issued/exec-rogue:/e2e-tls:ro" \
  -v "$PWD/mesh/tests/.e2e-pki/issued/controller-a/ca.crt:/e2e-real-ca.crt:ro" \
  -e RECEPTOR_NODE_ID=exec-rogue -e RECEPTOR_PEERS=mesh-e2e-receptor:27199 \
  -e RECEPTOR_TLS_CERT=/e2e-tls/tls.crt -e RECEPTOR_TLS_KEY=/e2e-tls/tls.key \
  -e RECEPTOR_TLS_CA=/e2e-real-ca.crt \
  -v "$PWD/mesh/tests/.e2e-pki/work-signing/work-public.pem:/e2e-signing/work-public.pem:ro" \
  -e RECEPTOR_WORK_PUBKEY=/e2e-signing/work-public.pem \
  ansible-execution-node:e2e >/dev/null \
  || fail "could not start the unknown-CA rogue"
ra=0; rogue_absent mesh-e2e-rogue-ca "^exec-rogue " || ra=$?
docker rm -f mesh-e2e-rogue-ca >/dev/null 2>&1 || true
case $ra in
  0) pass "unknown client-CA cert rejected by the ingress";;
  1) fail "unknown-CA node JOINED the mesh";;
  *) fail "unknown-CA-rogue test setup broken (rogue not running) — not a proven rejection";;
esac

echo "== 17. node id ≠ certificate identity is rejected (§9.3) =="
# A VALID mesh cert (exec-e2e-a's) presented by a node CLAIMING to be someone
# else. Rejection here is even stronger than 15/16: receptor cross-checks its
# OWN node id against its OWN cert at startup and refuses to build a TLS client
# at all, so the container EXITS with an identity-mismatch error rather than
# running-but-not-joining. Assert exactly that — a clean exit or a different
# error would not prove the identity binding.
idlog=$(timeout 60 docker run --rm --network "$E2E_NET" \
  -v "$PWD/mesh/tests/.e2e-pki/issued/exec-e2e-a:/e2e-tls:ro" \
  -e RECEPTOR_NODE_ID=exec-imposter -e RECEPTOR_PEERS=mesh-e2e-receptor:27199 \
  -e RECEPTOR_TLS_CERT=/e2e-tls/tls.crt -e RECEPTOR_TLS_KEY=/e2e-tls/tls.key \
  -e RECEPTOR_TLS_CA=/e2e-tls/ca.crt \
  -v "$PWD/mesh/tests/.e2e-pki/work-signing/work-public.pem:/e2e-signing/work-public.pem:ro" \
  -e RECEPTOR_WORK_PUBKEY=/e2e-signing/work-public.pem \
  ansible-execution-node:e2e 2>&1) && \
  fail "identity-mismatch node started successfully (must be rejected)"
grep -qi "exec-imposter not found in certificate" <<<"$idlog" \
  && pass "valid cert with the WRONG node id refused at startup (identity binding enforced)" \
  || fail "identity-mismatch rejection not by identity binding; got: $(tail -1 <<<"$idlog")"

echo "== 18. an EXPIRED node certificate is rejected (§9.3) =="
docker run -d --rm --name mesh-e2e-rogue-exp --network "$E2E_NET" \
  -v "$PWD/mesh/tests/.e2e-pki/issued/exec-expired:/e2e-tls:ro" \
  -e RECEPTOR_NODE_ID=exec-expired -e RECEPTOR_PEERS=mesh-e2e-receptor:27199 \
  -e RECEPTOR_TLS_CERT=/e2e-tls/tls.crt -e RECEPTOR_TLS_KEY=/e2e-tls/tls.key \
  -e RECEPTOR_TLS_CA=/e2e-tls/ca.crt \
  -v "$PWD/mesh/tests/.e2e-pki/work-signing/work-public.pem:/e2e-signing/work-public.pem:ro" \
  -e RECEPTOR_WORK_PUBKEY=/e2e-signing/work-public.pem \
  ansible-execution-node:e2e >/dev/null \
  || fail "could not start the expired-cert rogue"
ra=0; rogue_absent mesh-e2e-rogue-exp exec-expired || ra=$?
docker rm -f mesh-e2e-rogue-exp >/dev/null 2>&1 || true
case $ra in
  0) pass "expired certificate rejected by the ingress";;
  1) fail "EXPIRED-cert node JOINED the mesh";;
  *) fail "expired-cert test setup broken (rogue not running)";;
esac

echo "== 19. a CONTROLLER cert from an unknown CA is rejected by the node (§9.3, reversed) =="
# a rogue INGRESS presenting rogue-CA server certs; a legitimately certified
# probe node dials it and must refuse the server. Proof is the probe's own TLS
# verification error — the reverse direction of check 16.
docker run -d --rm --name mesh-e2e-rogue-ingress --network "$E2E_NET" \
  -v "$PWD/mesh/tests/.e2e-pki/rogue/issued/exec-rogue:/tls:ro" \
  -u 0:0 --entrypoint sh \
  quay.io/ansible/receptor:v1.6.7@sha256:6296f6cd3b0301cc7c9376e48ae15a42fc7b606235d08e94543fe77661cea4d2 \
  -euc 'mkdir -p /tmp/rc && printf -- "---\n- node:\n    id: exec-rogue\n- tls-server:\n    name: t\n    cert: /tls/tls.crt\n    key: /tls/tls.key\n- tcp-listener:\n    port: 27199\n    tls: t\n" > /tmp/rc/r.yml && exec receptor -c /tmp/rc/r.yml' >/dev/null \
  || fail "could not start the rogue ingress"
docker run -d --rm --name mesh-e2e-probe --network "$E2E_NET" \
  -v "$PWD/mesh/tests/.e2e-pki/issued/exec-probe:/e2e-tls:ro" \
  -e RECEPTOR_NODE_ID=exec-probe -e RECEPTOR_PEERS=mesh-e2e-rogue-ingress:27199 \
  -e RECEPTOR_TLS_CERT=/e2e-tls/tls.crt -e RECEPTOR_TLS_KEY=/e2e-tls/tls.key \
  -e RECEPTOR_TLS_CA=/e2e-tls/ca.crt \
  -v "$PWD/mesh/tests/.e2e-pki/work-signing/work-public.pem:/e2e-signing/work-public.pem:ro" \
  -e RECEPTOR_WORK_PUBKEY=/e2e-signing/work-public.pem \
  ansible-execution-node:e2e >/dev/null \
  || { docker rm -f mesh-e2e-rogue-ingress >/dev/null 2>&1; fail "could not start the probe node"; }
# Fail-closed by design: an unrecognised outcome FAILS. The diagnostics tell
# the operator which way it went wrong — probe died, or receptor's log wording
# changed — with the actual log tail, so a wording drift is a visible test
# maintenance task rather than a silent mystery.
verdict= plog= seen_running=0
deadline=$((SECONDS + 30))
while [ $SECONDS -lt $deadline ]; do
  plog=$(docker logs mesh-e2e-probe 2>&1 || true)
  if grep -qiE "certificate signed by unknown authority|failed to verify certificate|x509" <<<"$plog"; then verdict=refused; break; fi
  if grep -qi "Connection established" <<<"$plog"; then verdict=connected; break; fi
  # `docker run -d` returns before the container necessarily reaches Running,
  # so "not running" only means "died" after it was OBSERVED running once —
  # otherwise the first iteration could misfire before receptor comes up. The
  # deadline still bounds a container that never starts.
  if docker inspect --format '{{.State.Running}}' mesh-e2e-probe 2>/dev/null | grep -q true; then
    seen_running=1
  elif [ "$seen_running" = 1 ]; then
    verdict=died; break
  fi
  sleep 2
done
docker rm -f mesh-e2e-probe mesh-e2e-rogue-ingress >/dev/null 2>&1 || true
case "$verdict" in
  refused)   pass "node refused the unknown-CA controller (TLS verification error logged)";;
  connected) fail "node CONNECTED to an unknown-CA controller";;
  died)      fail "probe node exited before producing a verdict; log tail: $(tail -2 <<<"$plog")";;
  *)         fail "no refusal or connection within 30s (receptor log wording changed?); log tail: $(tail -2 <<<"$plog")";;
esac

echo "== 20. Tier-1 ingress failover (§9.7): stop sidecar A, dispatch through B =="
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

echo "== 21. transient SSH key copy is destroyed after the job (Phase 7) =="
# The job from check 9 staged /e2e-ssh/id_ed25519 into its PDD env/. The
# artifacts and meta.json must survive; the key copy must not. Fail CLOSED:
# a missing PDD means the probe itself is wrong, not that cleanup worked.
key_state=$(docker exec mesh-e2e-orchestrator bash -euc "
  pdd=/var/lib/mesh/jobs/$job_id
  [ -d \"\$pdd\" ] || { echo no-pdd; exit 0; }
  if [ -e \"\$pdd/env/ssh_key\" ]; then echo key-present; else echo key-gone; fi")
case "$key_state" in
  key-gone)    pass "staged env/ssh_key removed; artifacts retained";;
  key-present) fail "transient ssh key copy still present in the job dir";;
  no-pdd)      fail "job dir for $job_id vanished — cannot prove key cleanup";;
  *)           fail "key-cleanup probe returned '$key_state'";;
esac

echo "== 22. artifacts published to the operator log tree (Phase 7) =="
# mesh-run exports stdout/rc/job_events/meta.json per job to
# /var/log/ansible/runner/<job-id>/ — the tree the compose setup exposes on
# the host as logs/runner/. The final meta must carry the terminal status.
log_state=$(docker exec mesh-e2e-orchestrator bash -euc "
  d=/var/log/ansible/runner/$job_id
  [ -f \"\$d/rc\" ] && [ -f \"\$d/stdout\" ] || { echo missing-core; exit 0; }
  ev=\$(find \"\$d/job_events\" -name '*.json' 2>/dev/null | wc -l)
  st=\$(python3 -c \"import json; print(json.load(open('\$d/meta.json')).get('status',''))\" 2>&1) || st=\"unreadable: \$(tail -1 <<<\"\$st\")\"
  echo \"rc=\$(cat \"\$d/rc\") events=\$ev meta=\$st\"")
case "$log_state" in
  "rc=0 events="*)
    ev_n=$(sed -n 's/.*events=\([0-9]*\).*/\1/p' <<<"$log_state")
    meta_st=$(sed -n 's/.*meta=\(.*\)$/\1/p' <<<"$log_state")
    if [ -n "$ev_n" ] && [ "$ev_n" -gt 0 ] && [ "$meta_st" = succeeded ]; then
      pass "log tree complete ($log_state)"
    else
      fail "log tree incomplete: $log_state"
    fi;;
  missing-core) fail "no rc/stdout under /var/log/ansible/runner/$job_id";;
  *)            fail "unexpected log-tree state: $log_state";;
esac

echo "== 23. pool dispatch: classify -> healthy-node select -> dispatch-only failover (Phase 8) =="
# The pool lists a phantom first candidate that no ingress routes to; the
# dispatcher must skip it PRE-SUBMIT (nothing left the host) and run the job
# on the healthy second candidate. --zone exercises the classification hop
# too. Real two-node failover (UC3) differs only in the phantom being a dead
# real node — the skip logic is identical and is what Phase 8 adds.
docker exec mesh-e2e-orchestrator bash -euc '
  cat > /tmp/e2e-pools.yml <<EOF
pools:
  e2e:
    - node: exec-e2e-ghost
      max_concurrent: 2
    - node: exec-e2e-a
      max_concurrent: 2
EOF
  cat > /tmp/e2e-zones.yml <<EOF
zones:
  lab: { pool: e2e }
EOF
' || fail "could not stage pool/zone config on the orchestrator"
pool_out=$(docker exec mesh-e2e-orchestrator /usr/local/mesh/bin/mesh-run \
    --zone lab --pools-file /tmp/e2e-pools.yml --zones-file /tmp/e2e-zones.yml \
    --playbook /mesh-playbooks/mesh-ping.yml \
    --inventory /tmp/e2e-inv --ssh-key /e2e-ssh/id_ed25519 2>&1) \
  || fail "pool dispatch failed: $(tail -3 <<<"$pool_out")"
grep -q "node=exec-e2e-a " <<<"$pool_out" \
  && pass "zone 'lab' classified to pool 'e2e'; ghost skipped pre-submit; ran on exec-e2e-a" \
  || fail "pool dispatch did not select exec-e2e-a: $(grep -o 'node=[^ ]*' <<<"$pool_out" | head -1)"
pool_job=$(grep -o "job=[0-9a-f-]*" <<<"$pool_out" | cut -d= -f2)
pool_meta=$(docker exec mesh-e2e-orchestrator python3 -c "
import json
d = json.load(open('/var/lib/mesh/jobs/$pool_job/meta.json'))
print('ok' if d.get('pool') == 'e2e' and d.get('node') == 'exec-e2e-a' else 'bad: ' + json.dumps(d))
" 2>&1) || fail "pool job meta unreadable: $(tail -1 <<<"$pool_meta")"
[ "$pool_meta" = ok ] && pass "meta.json records pool=e2e node=exec-e2e-a" \
  || fail "pool meta wrong — $pool_meta"

echo "== 24. per-node concurrency cap: atomic slot reservation, not a work-list check (Phase 8) =="
# Cap the node at ONE slot, hold it with a slow job, and prove a second
# dispatch is refused PRE-SUBMIT while the first still completes cleanly.
# Fail CLOSED on both sides: the refusal must carry the nothing-was-executed
# claim, and the slow job must still exit 0 afterwards.
docker exec mesh-e2e-orchestrator bash -euc '
  cat > /tmp/e2e-pools-cap1.yml <<EOF
pools:
  e2e:
    - node: exec-e2e-a
      max_concurrent: 1
EOF
' || fail "could not stage the cap-1 pool config"
slow_log=/tmp/e2e-slow.$$.log
docker exec mesh-e2e-orchestrator /usr/local/mesh/bin/mesh-run \
    --pool e2e --pools-file /tmp/e2e-pools-cap1.yml \
    --playbook /mesh-playbooks/mesh-slow.yml \
    --inventory /tmp/e2e-inv --ssh-key /e2e-ssh/id_ed25519 >"$slow_log" 2>&1 &
slow_pid=$!
# Wait for the SLOT to actually be held, not a wall-clock guess: a slow
# docker-exec/python start could otherwise let job 2 win the empty slot and
# spuriously fail the check. flock -n on the same file from a probe process
# fails exactly while job 1's reservation is alive.
# flock -n exits 1 on contention specifically; any other nonzero (docker exec
# failing, container down) is a PROBE error and must be reported as such, not
# mistaken for a held slot.
slot_held=0
deadline=$((SECONDS + 30))
while [ $SECONDS -lt $deadline ]; do
  probe_rc=0
  probe_out=$(docker exec mesh-e2e-orchestrator sh -c \
    'flock -n /var/lib/mesh/slots/exec-e2e-a/slot.1 true' 2>&1) || probe_rc=$?
  case "$probe_rc" in
    0) sleep 1;;             # free (or not created yet) — keep waiting
    1) slot_held=1; break;;  # contention: job 1 holds the reservation
    *) kill "$slow_pid" 2>/dev/null || true
       fail "slot probe errored (rc=$probe_rc): $probe_out";;
  esac
done
[ "$slot_held" = 1 ] || { kill "$slow_pid" 2>/dev/null || true; fail "slow job never reserved the slot within 30s: $(tail -3 "$slow_log")"; }
cap_out=$(docker exec mesh-e2e-orchestrator /usr/local/mesh/bin/mesh-run \
    --pool e2e --pools-file /tmp/e2e-pools-cap1.yml \
    --playbook /mesh-playbooks/mesh-ping.yml \
    --inventory /tmp/e2e-inv --ssh-key /e2e-ssh/id_ed25519 2>&1) \
  && { kill "$slow_pid" 2>/dev/null || true; fail "second dispatch was ACCEPTED despite a full slot"; }
grep -q "nothing was executed" <<<"$cap_out" \
  && pass "second dispatch refused pre-submit while the slot was held" \
  || { kill "$slow_pid" 2>/dev/null || true; fail "refusal lacks the nothing-was-executed claim: $(tail -2 <<<"$cap_out")"; }
wait "$slow_pid" \
  && pass "slot-holding job still completed rc=0" \
  || fail "the slot-holding job failed: $(tail -3 "$slow_log")"
rm -f "$slow_log"

echo "== 25. unsigned work is refused (Phase 9) =="
# Every prior dispatch proved the SIGNED path (mesh-run submits --signwork).
# Now submit a raw unit WITHOUT --signwork: wherever receptor draws the line
# (refusal at submit, or the unit erroring on the node), the work must never
# execute. Fail CLOSED: a pending verdict after the deadline is a failure,
# and an executed unit is the vulnerability this check exists to block.
# The verdict must be SIGNATURE-SPECIFIC on every path, per this file's
# fail-closed rule: a submit that fails operationally (socket missing, node
# down) is a broken probe, not a proven refusal; and a unit that reaches a
# terminal state without a signature-related detail means verification never
# gated it (the worker choking on the bogus payload is NOT the property).
unsigned_out=$(docker exec mesh-e2e-orchestrator bash -euc '
  out=$(echo unsigned-probe | receptorctl --socket /run/receptor/receptor.sock \
        work submit ansible-runner --node exec-e2e-a --payload - 2>&1) || {
    if grep -qiE "sign|verif" <<<"$out"; then
      echo "verdict=refused-at-submit detail=$(tr "\n" " " <<<"$out" | tail -c 200)"
    else
      echo "verdict=submit-error detail=$(tr "\n" " " <<<"$out" | tail -c 200)"
    fi
    exit 0; }
  unit=$(awk "/^Unit ID:/ {print \$3}" <<<"$out")
  [ -n "$unit" ] || { echo "verdict=no-unit detail=$(tr "\n" " " <<<"$out" | tail -c 200)"; exit 0; }
  verdict=pending st=
  deadline=$((SECONDS + 30))
  while [ $SECONDS -lt $deadline ]; do
    st=$(receptorctl --socket /run/receptor/receptor.sock work list --unit_id "$unit" 2>&1 || true)
    if grep -qiE "Failed|Succeeded|Rejected|Error" <<<"$st"; then
      if grep -qiE "sign|verif" <<<"$st"; then verdict=refused; else verdict=terminal-unsigned-gap; fi
      break
    fi
    sleep 2
  done
  receptorctl --socket /run/receptor/receptor.sock work release "$unit" >/dev/null 2>&1 || true
  echo "verdict=$verdict detail=$(tr "\n" " " <<<"$st" | tail -c 200)"
') || fail "unsigned-work probe could not run"
case "$unsigned_out" in
  verdict=refused" "*|verdict=refused-at-submit" "*)
    pass "unsigned submission refused with a signature error (${unsigned_out#verdict=})";;
  verdict=terminal-unsigned-gap*)
    fail "unit reached a terminal state WITHOUT a signature refusal — verification may not be enforced: $unsigned_out";;
  *)
    fail "no signature-specific refusal for unsigned work: $unsigned_out";;
esac

echo "== 26. the packaged node compose file joins the mesh and runs work (mesh/compose.node.yml) =="
# mesh/compose.node.yml is the node-side deployment file operators run. Start
# a SECOND node from it exactly as the README says to — identity, peers, image,
# and bundle through its documented variables; the networks through the
# documented override shape (e2e.node-override.yml joins the suite's networks
# the way a site override joins a macvlan) — then prove it joined through an
# ingress and executed signed work on the target. Fail CLOSED: a file that no
# longer starts, a node that starts but never joins, and one that joins but
# does not run the play all fail. The suite's own COMPOSE_PROJECT_NAME must not
# leak into this project (it would collide with the lab's), hence env -u.
node_compose() {
  env -u COMPOSE_PROJECT_NAME \
    MESH_NODE_PROJECT=mesh-e2e-node-b \
    RECEPTOR_NODE_ID=exec-e2e-b \
    RECEPTOR_PEERS=mesh-e2e-receptor:27199,mesh-e2e-receptor-b:27199 \
    MESH_NODE_IMAGE=ansible-execution-node:e2e \
    MESH_NODE_TLS_DIR="$PWD/mesh/tests/.e2e-pki/issued/exec-e2e-b" \
    MESH_NODE_WORK_PUBKEY="$PWD/mesh/tests/.e2e-pki/work-signing/work-public.pem" \
    E2E_PROJECT="${COMPOSE_PROJECT_NAME:-mesh-e2e}" \
    docker compose -f mesh/compose.node.yml -f mesh/tests/e2e.node-override.yml "$@"
}
node_up=$(node_compose up -d --wait --wait-timeout 90 2>&1) \
  && pass "compose.node.yml started mesh-node-exec-e2e-b healthy (the image's HEALTHCHECK: receptorctl status on its control socket)" \
  || { docker logs mesh-node-exec-e2e-b 2>&1 | tail -20 || true; fail "packaged node did not come up healthy: $(tail -3 <<<"$node_up")"; }
deadline=$((SECONDS + 60)); joined=0
while [ $SECONDS -lt $deadline ]; do
  st=$(docker exec mesh-e2e-receptor receptorctl --socket /run/receptor/receptor.sock status 2>/dev/null || true)
  if grep -q "exec-e2e-b" <<<"$st"; then joined=1; break; fi
  sleep 3
done
[ "$joined" = 1 ] \
  && pass "exec-e2e-b joined via ingress A (mTLS + work verification rendered from the file's env)" \
  || { docker logs mesh-node-exec-e2e-b 2>&1 | tail -20 || true; fail "exec-e2e-b never appeared in receptorctl status within 60s"; }
b_out=$(docker exec mesh-e2e-orchestrator /usr/local/mesh/bin/mesh-run \
    --node exec-e2e-b --playbook /mesh-playbooks/mesh-ping.yml \
    --inventory /tmp/e2e-inv --ssh-key /e2e-ssh/id_ed25519 2>&1) \
  || fail "mesh-run to the packaged node failed: $(tail -3 <<<"$b_out")"
b_host=$(docker exec mesh-node-exec-e2e-b hostname)
grep -q "EXECUTED-ON=${b_host} " <<<"$b_out" \
  && pass "play executed on the packaged node (${b_host}) with rc=0 across the mesh" \
  || fail "play did not report executing on exec-e2e-b (${b_host}): $(grep -o "EXECUTED-ON=[^ ]*" <<<"$b_out" | head -1)"
node_down=$(node_compose down 2>&1) \
  && pass "packaged node torn down with the same file" \
  || fail "compose.node.yml down failed: $(tail -3 <<<"$node_down")"

echo "== 27. a node that DIED is never hung on: skipped pre-submit, or the watchdog aborts (issue #77) =="
# Two independent guards, one property: mesh-run must TERMINATE on a dead node,
# never block forever. (a) routable_via reads the ROUTE table, not the Known
# Node table (which keeps a disconnected node listed) — so a node that has
# died is skipped pre-submit; (b) if a node dies AFTER submit, a liveness
# watchdog stops the results stream. Stop the suite's node and dispatch to it
# under a hard timeout: a regression (submit-then-block) trips the timeout and
# fails. MESH_RESULTS_GRACE is shortened so the watchdog path, if taken, is
# quick. Fail CLOSED: an unrecognised outcome fails.
docker stop mesh-e2e-node-a >/dev/null || fail "could not stop the execution node"
dead_start=$SECONDS
# `|| dead_rc=$?` (not a bare assignment) so mesh-run's expected nonzero exit on
# a dead node does not trip `set -e` before the outcome is judged. A hard timeout
# bounds a regression: coreutils `timeout` exits 124, the macOS perl-shim (top of
# this file) exits 142 on SIGALRM — both mean "hung".
dead_rc=0
dead_out=$(timeout 90 docker exec \
  -e MESH_RESULTS_GRACE=10 -e MESH_RESULTS_POLL=3 \
  mesh-e2e-orchestrator /usr/local/mesh/bin/mesh-run \
    --node exec-e2e-a --playbook /mesh-playbooks/mesh-ping.yml \
    --inventory /tmp/e2e-inv --ssh-key /e2e-ssh/id_ed25519 2>&1) || dead_rc=$?
docker start mesh-e2e-node-a >/dev/null || fail "could not restart the execution node"
case $dead_rc in
  124|142) fail "mesh-run HUNG on a dead node (submitted, then blocked in work results) — issue #77 regressed";;
  0)       fail "mesh-run reported SUCCESS dispatching to a stopped node: $(tail -1 <<<"$dead_out")";;
esac
if grep -qiE "not routable|not selectable|nothing was executed" <<<"$dead_out"; then
  pass "dead node skipped pre-submit; failed fast in $((SECONDS - dead_start))s, nothing executed"
elif grep -qiE "results stream did not complete|unroutable for" <<<"$dead_out"; then
  pass "dead node's stream aborted by the liveness watchdog in $((SECONDS - dead_start))s (never hung)"
else
  fail "unexpected outcome on a dead node (rc=$dead_rc): $(tail -2 <<<"$dead_out")"
fi
# The node must re-join before the suite ends (a local re-run reuses this env).
deadline=$((SECONDS + 60)); rejoined=0
while [ $SECONDS -lt $deadline ]; do
  st=$(docker exec mesh-e2e-receptor receptorctl --socket /run/receptor/receptor.sock status 2>/dev/null || true)
  if grep -q 'exec-e2e-a' <<<"$st"; then rejoined=1; break; fi
  sleep 3
done
[ "$rejoined" = 1 ] && pass "execution node re-joined after restart" \
  || fail "execution node did not re-join within 60s of restart"
# If the watchdog path ran it left a results-incomplete unit + .hold marker;
# clear both so the environment is clean for a re-run.
docker exec mesh-e2e-orchestrator sh -c '
  for u in $(receptorctl --socket /run/receptor/receptor.sock work list 2>/dev/null \
             | python3 -c "import sys,json;[print(k) for k in json.load(sys.stdin)]" 2>/dev/null); do
    receptorctl --socket /run/receptor/receptor.sock work cancel "$u" >/dev/null 2>&1 || true
    receptorctl --socket /run/receptor/receptor.sock work release "$u" >/dev/null 2>&1 || true
  done
  rm -f /var/lib/mesh/slots/*/slot.*.hold 2>/dev/null || true
' || true

echo "All mesh e2e regression checks passed."
