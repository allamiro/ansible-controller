"""Prepare private, disposable gitlab-audit fixtures; never reuse live lab secrets."""
import os
from pathlib import Path
import secrets
import subprocess

HERE=Path(__file__).resolve().parent
ROOT=HERE.parent.parent
STATE=HERE/'.state'


def run(*args, **kwargs):
    subprocess.run(args, check=True, **kwargs)


def main():
    STATE.mkdir(exist_ok=True)
    if (STATE/'prepared').exists():
        print('Fixtures already prepared; keeping existing keys and volumes.')
        return
    if (STATE/'lab.env').exists():
        raise SystemExit('Partial or existing fixtures: inspect .state before reinitializing; keys will not be replaced.')
    for p in ('web-tls','fetch-secrets','ci-authorized','target-key','target-authorized'):
        (STATE/p).mkdir(exist_ok=True)
    (STATE/'lab.env').write_text('AUDIT_ROOT_PASSWORD=Audit'+secrets.token_hex(24)+'\n')
    (STATE/'lab.env').chmod(0o600)
    (STATE/'fips0').write_text('0\n')
    (STATE/'environments.yml').write_text('{}\n')
    (STATE/'target-key/known_hosts').touch()
    (STATE/'nginx.conf').write_text('''events {}
http {
 server { listen 443 ssl; server_name gitlab.audit.local;
 ssl_certificate /tls/server.crt; ssl_certificate_key /tls/server.key;
 client_max_body_size 64m;
 location / { proxy_pass http://gitlab:8929; proxy_set_header Host $host; proxy_set_header X-Forwarded-Proto https; } }
 server { listen 8929; location / { proxy_pass http://gitlab:8929; } }
}
''')
    tls=STATE/'web-tls'
    run('openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(tls/'ca.key'),'-out',str(tls/'ca.crt'),'-days','30','-subj','/CN=GitLab Audit CA','-addext','keyUsage=critical,keyCertSign,cRLSign',stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    run('openssl','req','-newkey','rsa:2048','-nodes','-keyout',str(tls/'server.key'),'-out',str(tls/'server.csr'),'-subj','/CN=gitlab.audit.local',stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    (tls/'ext').write_text('subjectAltName=DNS:gitlab.audit.local,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n')
    run('openssl','x509','-req','-in',str(tls/'server.csr'),'-CA',str(tls/'ca.crt'),'-CAkey',str(tls/'ca.key'),'-CAcreateserial','-out',str(tls/'server.crt'),'-days','30','-extfile',str(tls/'ext'),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    for key in ('ca.key','server.key'):
        (tls/key).chmod(0o600)
    env=dict(os.environ,MESH_SECRETS=str(STATE/'pki'))
    for script,args in [('mesh-ca-init',['audit-ca']),('controller-cert',['controller-a','ingress-a']),('controller-cert',['controller-b','ingress-b']),('node-csr',['exec-audit-a']),('node-sign',['csr/exec-audit-a.csr','exec-audit-a']),('work-sign-init',[])]:
        run('bash',str(ROOT/'mesh/pki'/f'{script}.sh'),*args,env=env,cwd=ROOT)
    script='''set -eu
cp /state/pki/csr/exec-audit-a.key /state/pki/issued/exec-audit-a/tls.key
ssh-keygen -q -t ed25519 -N '' -f /state/target-key/id_ed25519
ssh-keygen -q -t ed25519 -N '' -f /state/ci-key
cp /state/target-key/id_ed25519.pub /state/target-authorized/authorized_keys
printf 'restrict,command="/usr/local/lab-bin/ctl-shell" %s\n' "$(cat /state/ci-key.pub)" > /state/ci-authorized/authorized_keys
chown -R 1000:1000 /state/ci-authorized /state/target-authorized /state/target-key /state/pki/issued/exec-audit-a
chmod 700 /state/ci-authorized /state/target-authorized
chmod 600 /state/ci-authorized/authorized_keys /state/target-authorized/authorized_keys
chmod 644 /state/pki/work-signing/work-public.pem
'''
    run('docker','run','--rm','-i','-v',str(STATE)+':/state','--entrypoint','bash','ansible-controller:e2e',input=script.encode())
    (STATE/'prepared').touch()
    print('Fixtures ready. Start Compose, then run bootstrap.py after GitLab becomes healthy.')


if __name__=='__main__':
    main()
