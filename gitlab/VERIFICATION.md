# GitLab CE verification and support

The Community Edition workflow has been tested with GitLab CE 19.3.1 and Runner
19.3.1 in a dedicated `gitlab-audit` stack, separate from the existing deployment.
The latest workflow checks were run on **2026-09-09**. Version pins identify the
tested configuration; they are not a claim about the latest available release.

Use the [Maintainer guide](MAINTAINER-README.md) for normal operation and the
[test README](tests/README.md) to reproduce the checks.

## Verified workflow

| Behavior | Result |
|---|---|
| Push, validation, manual release and real mesh execution | Passed; target execution marker increased once |
| GitLab result artifacts | Run record, mesh metadata, stdout and JSON events downloaded successfully |
| Successful deployment Retry | Original run ID and mesh UUID returned; target marker unchanged |
| Failed playbook Retry | Both jobs retained failure and exported the same execution record |
| Developer release and artifact download | Both denied by GitLab |
| Named Maintainer release and download | Both succeeded |
| Collect original mesh UUID through CI | Original result exported without redispatch |
| Export while another dispatch holds the environment lock | Passed local regression |
| CE request for native protected environments | Rejected; optional provisioning did not apply an unprotected fallback |

The successful execution used pipeline 5/job 12; Retry used job 14. Failure and
Retry used pipeline 6/jobs 16 and 18. Maintainer release used job 20, and collection
used job 13. These IDs belong to the isolated test instance. Private evidence is
retained in `tests/.state/ci-acceptance.json`; the stack was stopped after testing.

Local command regressions at completion: **39 passed, 3 container-only cases
skipped**. The skipped cases require mounted site configuration, a Vault file,
or an isolated mesh transport stand-in. Separate live tests exercised actual
mesh dispatch and result retrieval. CI also passed image builds, smoke tests,
lint and the mesh end-to-end suite.

## Additional tested boundaries

Earlier isolated tests verified standalone SSH execution, private-CA GitLab
fetches, rejection of a wrong TLS hostname, pinned controller host keys, forced
command rejection, input validation, project symlink/LFS rejection, and continued
native execution after GitLab services were stopped. Ingress loss before
submission and two independently configured controllers were also exercised.
Sanitized earlier results are in [tests/evidence.json](tests/evidence.json).

## Support limits

| Area | Current boundary |
|---|---|
| Community Edition approval | Protected branches, Maintainer merge, successful validation and manual release; no mandatory reviewer count |
| Request deduplication | One persistent controller and one environment/project/pipeline/playbook identity; new pipelines are new requests |
| Controller HA | No distributed request ownership, shared scheduler or fencing guarantee |
| Node scaling | Enrollment and selection exist; automatic provisioning and scaling are not implemented |
| Windows targets | Configuration guidance exists; live Windows execution has not been verified |
| GitLab TLS | Lab HTTP and private CA with proxy termination tested; public CA, rotation and every proxy topology not live tested |
| Ambiguous submission | Requires reconciliation of original work; no automatic resubmission |
| State loss | Deleting request claims removes retry protection; disaster recovery is not verified |
| Optional licensed approvals | API provisioning tested with fixtures; no licensed instance available for live multi-approver tests |
| Existing-project upgrades | Require reviewed pipeline/helper updates and administrator-managed connections |

Detailed development history is preserved in the
[internal audit archive](../docs/internal/gitlab/VERIFICATION-HISTORY.md).
