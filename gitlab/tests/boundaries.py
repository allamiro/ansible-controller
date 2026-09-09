"""Read-only trust and network checks against gitlab-audit fixtures."""
import json
from pathlib import Path
import subprocess

HERE=Path(__file__).resolve().parent
STATE=HERE/'.state'
results=[]


def check(name,args,expected):
    try:
        p=subprocess.run(args,capture_output=True,text=True,timeout=30)
        result={'case':name,'rc':p.returncode,'expected':expected,'pass':p.returncode==expected}
    except (subprocess.TimeoutExpired, OSError) as error:
        result={'case':name,'rc':None,'expected':expected,'pass':False,'error':type(error).__name__}
    print(json.dumps(result),flush=True); results.append(result)
    (STATE/'boundary-results.json').write_text(json.dumps(results,indent=2))


def main():
    tls_probe = """import socket,ssl,sys
ctx=ssl.create_default_context(cafile='/etc/audit-ca.crt' if sys.argv[1]=='trusted' else None)
try:
 with socket.create_connection(('gitlab.audit.local',443),timeout=8) as sock:
  with ctx.wrap_socket(sock,server_hostname=sys.argv[2]): pass
except ssl.SSLCertVerificationError: sys.exit(60)
"""
    base=['docker','exec','gitlab-audit-controller-1','python3','-c',tls_probe]
    check('private-ca-trusted',base+['trusted','gitlab.audit.local'],0)
    check('private-ca-not-trusted',base+['untrusted','gitlab.audit.local'],60)
    check('tls-wrong-hostname',base+['trusted','wrong.audit.local'],60)
    # Run from GitLab itself, which has no membership in the control network.
    controller=json.loads(subprocess.check_output(['docker','inspect','gitlab-audit-controller-1']))[0]['NetworkSettings']['Networks']['gitlab-audit_control']['IPAddress']
    check('gitlab-cannot-dial-controller',['docker','exec','gitlab-audit-gitlab-1','/opt/gitlab/embedded/bin/ruby','-rsocket','-rtimeout','-e',f'begin; Timeout.timeout(3) {{ TCPSocket.new("{controller}",22).close }}; exit 1; rescue Timeout::Error, SystemCallError; exit 0; end'],0)
    ssh=['docker','run','--rm','--network','gitlab-audit_control','-v',str(STATE/'ci-key')+':/key:ro','-v',str(STATE/'ctl-known-hosts')+':/kh:ro','--entrypoint','ssh','ansible-controller:e2e','-i','/key','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile=/kh']
    check('forced-command-refuses-shell',ssh+['ansible@controller','id'],2)
    untrusted=ssh.copy(); untrusted[-1]='/dev/null'
    check('ssh-untrusted-hostkey',untrusted+['ansible@controller','ctl-run','--collect','abcd'],255)
    (STATE/'boundary-results.json').write_text(json.dumps(results,indent=2))
    raise SystemExit(0 if all(r['pass'] for r in results) else 1)


if __name__=='__main__': main()
