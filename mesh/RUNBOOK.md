# Mesh Operator Runbook

Step-by-step procedures for operating the distributed execution mesh:
creating the trust anchors, enrolling nodes, verifying health, running jobs,
rotating credentials, evicting nodes, and troubleshooting. The
[README](README.md) explains what the mesh is; this page is what you type.

All commands run from the repository root on the machine indicated by each
heading. `mesh/secrets/` is gitignored — nothing you create here can be
committed.

---

## 1. Create the trust anchors (once, offline machine)

The offline machine needs Docker (with the pinned receptor image preloaded —
see the [README prerequisites](README.md#what-youll-need)) and `openssl`.

```bash
mesh/pki/mesh-ca-init.sh "my mesh CA"     # the CA — ca.key NEVER leaves this machine
mesh/pki/work-sign-init.sh                # the work-signing pair
```

Then issue the two control-plane identities:

```bash
mesh/pki/controller-cert.sh controller-a receptor-controller
mesh/pki/controller-cert.sh controller-b receptor-controller-b
```

Copy to the **control host**:
- `mesh/secrets/receptor/issued/controller-a/` and `issued/controller-b/`
- `mesh/secrets/receptor/work-signing/work-private.pem`

Keep on the **offline machine**: `ca/ca.key` (forever) and
`work-signing/` (the canonical pair; only the public half is distributed).

## 2. Enroll an execution node

Every `mesh/pki/` script reads and writes the secrets tree
`mesh/secrets/receptor/` (`MESH_SECRETS`); the `csr/`, `issued/`, and
`work-signing/` paths below are relative to it, and the packaged node file's
defaults point at the same tree.

```bash
# ON THE NODE HOST — key + signing request; the key never leaves:
mesh/pki/node-csr.sh exec-dmz-a
# transfer csr/exec-dmz-a.csr to the offline machine

# ON THE OFFLINE MACHINE — sign (refuses a CSR whose identity doesn't match):
mesh/pki/node-sign.sh csr/exec-dmz-a.csr exec-dmz-a
# transfer issued/exec-dmz-a/ (tls.crt + ca.crt) back to the node host

# ON THE NODE HOST — assemble the bundle:
cp csr/exec-dmz-a.key issued/exec-dmz-a/tls.key
chmod 600 issued/exec-dmz-a/tls.key
# and place the work-signing PUBLIC key beside it:
#   work-signing/work-public.pem  (from the offline machine — public half only)
```

Start the node from the packaged file. Put `compose.node.yml` and
`node.env.example` (both in `mesh/`) on the node host beside the
`secrets/receptor/` tree the steps above produced — the file's defaults point
at `secrets/receptor/issued/<node id>/` and
`secrets/receptor/work-signing/work-public.pem`, mounted read-only:

```bash
chown -R 1000:1000 secrets/receptor/issued/exec-dmz-a   # the container reads the bundle as uid 1000
cp node.env.example .env                                # set RECEPTOR_NODE_ID and RECEPTOR_PEERS
docker compose -f compose.node.yml up -d --wait
docker compose -f compose.node.yml logs -f              # both ingress connections come up
```

The rendered receptor config lives on tmpfs, the node restarts with its host,
and every setting — image tag, bundle location, log level, several nodes on
one host — is documented at the top of the file.

<details>
<summary>Equivalent <code>docker run</code>, for a host without compose</summary>

```bash
docker run -d --name mesh-node-exec-dmz-a --restart unless-stopped \
  --tmpfs /run/receptor:uid=1000,gid=1000,mode=0750 \
  -v "$PWD/secrets/receptor/issued/exec-dmz-a":/etc/receptor/tls:ro \
  -v "$PWD/secrets/receptor/work-signing/work-public.pem":/etc/receptor/signing/work-public.pem:ro \
  -e RECEPTOR_NODE_ID=exec-dmz-a \
  -e RECEPTOR_PEERS=ctrl.example.com:27199,ctrl.example.com:27200 \
  -e RECEPTOR_TLS_CERT=/etc/receptor/tls/tls.crt \
  -e RECEPTOR_TLS_KEY=/etc/receptor/tls/tls.key \
  -e RECEPTOR_TLS_CA=/etc/receptor/tls/ca.crt \
  -e RECEPTOR_WORK_PUBKEY=/etc/receptor/signing/work-public.pem \
  ghcr.io/allamiro/ansible-execution-node:latest
```

</details>

Add the node to `mesh/config/pools.yml` (and a zone in `zones.yml`) so pool
dispatch can select it — config is read per dispatch, no restart needed.

## 3. Start the control plane and verify

```bash
make mesh-up            # controller + ingress A (host :27199) + ingress B (host :27200)
make mesh-status        # the node must appear in Known Nodes on at least one ingress
make mesh-ping NODE=exec-dmz-a
```

For a full-path proof before touching production targets, run the
[ten-minute lab](README.md#try-it-in-ten-minutes); pulled images can be
verified with cosign
([README — Getting the images](README.md#getting-the-images)).

## 4. Run jobs

```bash
make mesh-run NODE=exec-dmz-a PLAYBOOK=site.yml INVENTORY=inventory/dmz.ini
make mesh-run ZONE=dmz        PLAYBOOK=site.yml INVENTORY=inventory/dmz.ini
```

Results: live output in the terminal, the playbook's real exit code as `$?`,
artifacts on the host under `logs/runner/<job-id>/`, and the lifecycle record
in its `meta.json` ([README — Running a job](README.md#running-a-job)).

## 5. Rotate credentials

**A node certificate** (before its `notAfter`, or on suspicion):
repeat [enrollment](#2-enroll-an-execution-node) for the same node id —
new CSR on the node, sign offline, install the new bundle, restart the node
container. The old certificate simply stops being presented.

**A controller identity**: reissue with `controller-cert.sh`, replace the
`issued/controller-*/` directory on the control host, restart that sidecar
(`docker restart receptor-controller` or `receptor-controller-b`) — one at a
time, so the other ingress keeps serving.

**The work-signing pair** — order matters, nodes verify with exactly one key:

```bash
# offline machine:
mesh/pki/work-sign-init.sh --force          # prints the orphaning warning
# 1. distribute the NEW work-public.pem to EVERY node, restart each node
# 2. only then replace work-private.pem on the control host and restart both sidecars
# 3. verify: make mesh-run NODE=... PLAYBOOK=ping.yml
```

Nodes verify against a single key, so any rotation has a refusal window: a
node holding the new public key refuses old-signed submissions from the
moment it restarts (step 1) until the sidecars switch keys (step 2).
Nodes-first is still the right order because the window CLOSES with the
one-host sidecar swap you control — reversed, it drags on until the slowest
node in the slowest network gets its new key. Jobs already running are
unaffected either way; schedule the rotation in a quiet period.

**The CA itself** (compromise, or planned expiry): a new CA orphans every
issued certificate. Issue the new CA offline, then re-run enrollment for the
controllers and every node, restarting each as its new bundle lands. Plan a
maintenance window; the mesh has no cross-CA trust on purpose.

## 6. Evict a node

Receptor has no certificate revocation list, so eviction is containment plus
(if the key may be compromised) rotation:

1. Remove the node from `mesh/config/pools.yml` / `zones.yml` — pool dispatch
   stops selecting it immediately.
2. Stop the node container; block its host at your firewall if you don't
   control it (the ingress ports 27199/27200 are its only way in, and it must
   present its certificate — but a stolen VALID certificate still admits it).
3. If the node's key may be compromised: rotate the CA (above). A valid
   certificate cannot otherwise be un-issued.

Note what eviction does **not** threaten: even an admitted rogue node cannot
submit work to others (work signing) and receives only jobs explicitly
dispatched to it.

## 7. Troubleshoot

Start with the [README's symptom table](README.md#health-and-troubleshooting).
The places to look:

| Where | What's there |
|---|---|
| `make mesh-status` | which nodes each ingress can route to |
| `docker logs receptor-controller` (and `-b`) | ingress TLS handshake refusals — certless/unknown-CA/expired/wrong-identity peers show up here |
| `docker logs <node container>` | node-side dial/TLS errors; work-verification refusals |
| `logs/runner/<job-id>/` on the host | per-job stdout, `rc`, events, final `meta.json` |
| `/var/lib/mesh/jobs/<job-id>/` in the orchestrator | the authoritative job record |
| `/var/lib/mesh/slots/<node>/` in the orchestrator | concurrency state: `slot.N`, `.hold` markers (unknown-outcome jobs), the persisted `cap` |
| `receptorctl work list` (either socket) | units the mesh still tracks — the first stop after an ambiguous submit |

The e2e suite doubles as a diagnostic vocabulary: every failure mode it
proves (27 checks) is one the mesh is supposed to refuse — if production
shows different behavior than the lab, compare configurations first.
