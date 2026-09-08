# mesh-automation

Git-managed Ansible automation, executed through the Receptor mesh.

- `playbooks/` — the automation. `site.yml` stamps the reviewed commit onto
  the target; `ping.yml` proves connectivity.
- `inventory/lab.ini` — the isolated lab target.
- `.gitlab-ci.yml` — validate on every branch/MR; manual, protected-ref-only
  deploy through the mesh; manual collect for interrupted result recovery.
- `scripts/` — the deploy guard (no-resubmission across CI retries,
  commit stamping, sanitized artifacts) and the collect wrapper.

Workflow: branch → change → MR (validate runs) → review/approve → merge to
protected `main` → manually release the `deploy` job → artifacts return to
the pipeline; the target records `commit=<sha>`.
