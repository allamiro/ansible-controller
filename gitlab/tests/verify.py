"""Exercise real pipelines in the dedicated disposable stack, recording evidence."""
import importlib.util
import json
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('audit_bootstrap', HERE/'bootstrap.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
RESULTS = json.loads((b.STATE/'results.json').read_text()) if (b.STATE/'results.json').exists() else []

CURRENT_RESULTS = []

def run_case(name, environment='audit-direct', playbook='playbooks/site.yml', expected='success', controller='controller'):
    p = b.api('POST', '/projects/1/pipeline', {'ref':'main','variables':[
        {'key':'CTL_HOST','value':controller}, {'key':'AUDIT_ENV','value':environment}, {'key':'PLAYBOOK','value':playbook}]})
    deadline = time.monotonic()+240
    while time.monotonic() < deadline:
        p = b.api('GET', f"/projects/1/pipelines/{p['id']}")
        if p['status'] in ('success','failed','canceled','skipped'):
            break
        time.sleep(3)
    jobs = b.api('GET', f"/projects/1/pipelines/{p['id']}/jobs")
    for job in jobs:
        req = urllib.request.Request(b.URL+f"/projects/1/jobs/{job['id']}/trace", headers={'PRIVATE-TOKEN':(b.STATE/'pat').read_text().strip()})
        with urllib.request.urlopen(req,timeout=30) as r:
            trace=r.read().decode()
        f=b.STATE/f"job-{job['id']}.log"; f.write_text(trace); f.chmod(0o600)
    result={'case':name,'pipeline':p['id'],'jobs':[j['id'] for j in jobs], 'status':p['status'],'expected':expected,'pass':p['status']==expected}
    RESULTS.append(result)
    CURRENT_RESULTS.append(result)
    (b.STATE/'results.json').write_text(json.dumps(RESULTS,indent=2))
    print(json.dumps(result),flush=True)
    return result


if __name__ == '__main__':
    run_case('standalone-private-ca')
    run_case('standalone-http-lab','audit-http')
    run_case('standalone-playbook-failure','audit-direct','playbooks/fail.yml','failed')
    run_case('mesh-private-ca','audit-mesh')
    run_case('mesh-playbook-failure','audit-mesh','playbooks/fail.yml','failed')
    try:
        b.docker('stop','gitlab-audit-ingress-a-1')
        run_case('mesh-ingress-a-down','audit-mesh')
    finally:
        b.docker('start','gitlab-audit-ingress-a-1')
    raise SystemExit(0 if all(r['pass'] for r in CURRENT_RESULTS) else 1)
