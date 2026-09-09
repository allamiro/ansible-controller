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
    v.run_case('mesh-node-returned','audit-mesh')
    raise SystemExit(0 if all(x['pass'] for x in v.RESULTS) else 1)
