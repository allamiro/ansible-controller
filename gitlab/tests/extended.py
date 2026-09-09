"""Additional independent-controller, credential denial and outage cases."""
import importlib.util
import json
from pathlib import Path

s=importlib.util.spec_from_file_location('v',Path(__file__).with_name('verify.py'))
v=importlib.util.module_from_spec(s);s.loader.exec_module(v)
b=v.b

if __name__=='__main__':
    v.run_case('second-independent-controller',controller='controller2')
    # Unknown inventory/environment must fail before reaching any target.
    v.run_case('unknown-environment','does-not-exist',expected='failed')
    envs=json.loads((b.STATE/'environments.yml').read_text())
    envs['environments']['audit-revoked']=envs['environments']['audit-direct'].copy()
    (b.STATE/'environments.yml').write_text(json.dumps(envs))
    f=b.STATE/'fetch-secrets/audit-revoked.token'; f.write_text('gitlab+deploy-token-invalid:revoked\n'); f.chmod(0o600)
    v.run_case('invalid-fetch-credential','audit-revoked',expected='failed')
    try:
        b.docker('stop','gitlab-audit-node-1')
        v.run_case('mesh-node-unavailable','audit-mesh',expected='failed')
    finally:
        b.docker('start','gitlab-audit-node-1')
    # A stopped-node case should be refused before submission. If routing lag
    # allowed an ambiguous submission, preserve it and require recovery rather
    # than treating the next dispatch as a clean availability test.
    unresolved = json.loads(b.docker('exec','gitlab-audit-controller-1','python3','-c',
        "import glob,json; print(json.dumps([p for p in glob.glob('/var/lib/mesh/jobs/*/meta.json') if json.load(open(p)).get('status') in ('created','submitting','running','submit-ambiguous','results-incomplete')]))"))
    assert not unresolved, f'Recover these original jobs before continuing: {unresolved}'
    v.run_case('mesh-node-returned','audit-mesh')
    raise SystemExit(0 if all(x['pass'] for x in v.CURRENT_RESULTS) else 1)
