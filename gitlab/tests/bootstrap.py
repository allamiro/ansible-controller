"""Bootstrap only the dedicated gitlab-audit Compose instance. No existing lab API use."""
import json
import secrets
import subprocess
import urllib.request
import urllib.error
from pathlib import Path

HERE = Path(__file__).resolve().parent
STATE = HERE / '.state'
URL = 'http://127.0.0.1:18929/api/v4'


def api(method, path, data=None):
    if data is None and method in ('POST', 'PUT'):
        data = {}
    req = urllib.request.Request(URL + path, method=method,
        data=json.dumps(data).encode() if data is not None else None,
        headers={'PRIVATE-TOKEN': (STATE/'pat').read_text().strip(),
                 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=60) as response:
        payload = response.read()
        return json.loads(payload) if payload else None


def docker(*args, **kwargs):
    return subprocess.run(['docker', *args], check=True, capture_output=True, text=True, **kwargs).stdout


def main():
    if (STATE/'bootstrap.done').exists():
        print('Project already bootstrapped; use verify.py.')
        return
    if (STATE/'bootstrap.started').exists() or (STATE/'project.json').exists():
        raise SystemExit('Partial bootstrap detected; inspect evidence and reset the disposable stack and .state before retrying.')
    # Exclusive marker covers crashes before any resource ID can be recorded.
    (STATE/'bootstrap.started').touch(exist_ok=False)
    if not (STATE/'pat').exists():
        token = 'glpat-' + secrets.token_hex(20)
        script = "u=User.find_by_username('root'); t=u.personal_access_tokens.create!(name:'isolated-audit',scopes:['api'],expires_at:2.days.from_now); t.set_token("+json.dumps(token)+"); t.save!\n"
        docker('exec', '-i', 'gitlab-audit-gitlab-1', 'gitlab-rails', 'runner', '-', input=script)
        (STATE/'pat').write_text(token)
        (STATE/'pat').chmod(0o600)
    print('GitLab version:', api('GET', '/version')['version'], flush=True)
    # Read authoritative host keys directly from our own fixtures, not keyscan.
    known=[]
    for host in ('direct-target','mesh-target'):
        hk=docker('exec',f'gitlab-audit-{host}-1','cat','/etc/ssh/host_keys/ssh_host_ed25519_key.pub').split()
        known.append(host+' '+' '.join(hk[:2]))
    # This file is owned by the target UID after prepare; write through Docker.
    docker('run','--rm','-i','-v',str(STATE)+':/state','--entrypoint','sh','ansible-controller:e2e','-c','cat > /state/target-key/known_hosts',input='\n'.join(known)+'\n')
    project = api('POST', '/projects', {'name':'audit-automation', 'visibility':'private', 'initialize_with_readme':True, 'default_branch':'main'})
    pid = project['id']
    pipeline = '''stages: [test]
audit:
  tags: [audit-deploy]
  image:
    name: ansible-controller:e2e
    entrypoint: [""]
  script:
    - chmod 600 "$CTL_SSH_KEY"
    - ssh -i "$CTL_SSH_KEY" -o UserKnownHostsFile="$CTL_KNOWN_HOSTS" -o StrictHostKeyChecking=yes -o BatchMode=yes ansible@${CTL_HOST:-controller} ctl-run --env "$AUDIT_ENV" --project "$CI_PROJECT_PATH" --sha "$CI_COMMIT_SHA" --playbook "$PLAYBOOK" --pipeline "$CI_PIPELINE_ID" --job "$CI_JOB_ID" --wait 15
'''
    play = '''- name: Prove execution
  hosts: all
  gather_facts: false
  tasks:
    - name: Verify remote connectivity
      ansible.builtin.ping:
    - name: Write isolated test marker
      ansible.builtin.copy:
        content: "audit execution\\n"
        dest: /home/ansible/audit-marker
        mode: "0600"
'''
    files = {'.gitlab-ci.yml': pipeline, 'playbooks/site.yml': play,
        'playbooks/fail.yml': '- hosts: all\n  gather_facts: false\n  tasks:\n    - ansible.builtin.fail:\n        msg: intentional audit failure\n',
        'playbooks/slow.yml': '- hosts: all\n  gather_facts: false\n  tasks:\n    - ansible.builtin.command: sleep 25\n',
        'inventory/direct.ini': 'direct-target ansible_user=ansible\n',
        'inventory/mesh.ini': 'mesh-target ansible_user=ansible\n',
        'ansible.cfg':'[defaults]\nhost_key_checking=True\n[ssh_connection]\nssh_args=-o UserKnownHostsFile=/target-key/known_hosts -o StrictHostKeyChecking=yes\n',
        # mesh stages the playbook directory; configure its node-local trust.
        'playbooks/ansible.cfg':'[defaults]\nhost_key_checking=True\n[ssh_connection]\nssh_args=-o UserKnownHostsFile=/known_hosts -o StrictHostKeyChecking=yes\n'}
    commit = api('POST', f'/projects/{pid}/repository/commits', {'branch':'main',
       'commit_message':'Seed isolated verification project',
       'actions':[{'action':'create','file_path':p,'content':c} for p,c in files.items()]})
    (STATE/'project.json').write_text(json.dumps({'id':pid, 'path':project['path_with_namespace'], 'sha':commit['id']}))
    deploy = api('POST', f'/projects/{pid}/deploy_tokens', {'name':'audit-fetch','scopes':['read_repository']})
    envs = {}
    for name, mode in [('audit-direct','standalone'), ('audit-mesh','mesh'), ('audit-http','standalone')]:
        envs[name] = {'mode':mode, 'gitlab_url':'https://gitlab.audit.local' if name != 'audit-http' else 'http://gitlab.audit.local:8929',
                     'allowed_projects':[project['path_with_namespace']],
                     'inventory':'inventory/mesh.ini' if mode=='mesh' else 'inventory/direct.ini',
                     'ssh_key':'/target-key/id_ed25519', 'git_ca_file':'/etc/audit-ca.crt'}
        if mode == 'mesh':
            envs[name]['node'] = 'exec-audit-a'
        f=STATE/'fetch-secrets'/f'{name}.token'
        f.write_text(deploy['username']+':'+deploy['token']+'\n'); f.chmod(0o600)
    # Existing bind mount retains inode; write in place.
    (STATE/'environments.yml').write_text(json.dumps({'environments':envs}))
    hk = docker('exec','gitlab-audit-controller-1','cat','/etc/ssh/host_keys/ssh_host_ed25519_key.pub').split()
    hk2 = docker('exec','gitlab-audit-controller2-1','cat','/etc/ssh/host_keys/ssh_host_ed25519_key.pub').split()
    (STATE/'ctl-known-hosts').write_text('controller '+' '.join(hk[:2])+'\ncontroller2 '+' '.join(hk2[:2])+'\n')
    for key,value,kind in [('CTL_SSH_KEY',docker('run','--rm','-v',str(STATE)+':/state:ro','--entrypoint','cat','ansible-controller:e2e','/state/ci-key'),'file'),
                           ('CTL_KNOWN_HOSTS',(STATE/'ctl-known-hosts').read_text(),'file'),
                           ('AUDIT_ENV','audit-direct','env_var'),('PLAYBOOK','playbooks/site.yml','env_var')]:
        api('POST',f'/projects/{pid}/variables',{'key':key,'value':value,'variable_type':kind,'protected':True})
    r=api('POST','/user/runners',{'runner_type':'project_type','project_id':pid,
        'description':'isolated-audit-deploy','tag_list':'audit-deploy',
        'access_level':'ref_protected','run_untagged':False,'locked':True})
    # Token via stdin-built configuration, never command-line arguments.
    config = f'''concurrent = 2
[[runners]]
  name = "isolated-audit-deploy"
  url = "https://gitlab.audit.local"
  clone_url = "https://gitlab.audit.local"
  token = {json.dumps(r['token'])}
  tls-ca-file = "/etc/gitlab-runner/certs/ca.crt"
  executor = "docker"
  [runners.docker]
    image = "ansible-controller:e2e"
    network_mode = "gitlab-audit_control"
    pull_policy = "if-not-present"
    volumes = [{json.dumps(str(STATE/'web-tls/ca.crt')+':/etc/gitlab-runner/certs/ca.crt:ro')}]
'''
    docker('exec','-i','gitlab-audit-runner-1','sh','-c',
           'umask 077; cat > /etc/gitlab-runner/config.toml',input=config)
    (STATE/'bootstrap.done').touch()
    print('Created isolated project', project['path_with_namespace'], 'id', pid, flush=True)


if __name__ == '__main__':
    main()
