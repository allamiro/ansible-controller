"""Test the actual seed CI YAML in a second isolated GitLab project."""
import importlib.util
import json
import time
from pathlib import Path

HERE=Path(__file__).resolve().parent
s=importlib.util.spec_from_file_location('audit_bootstrap', HERE/'bootstrap.py')
b=importlib.util.module_from_spec(s); s.loader.exec_module(b)


def wait_jobs(pid, pipeline, success_jobs=()):
    deadline=time.monotonic()+180
    jobs=[]
    completed=False
    while time.monotonic()<deadline:
        jobs=b.api('GET',f'/projects/{pid}/pipelines/{pipeline}/jobs')
        if jobs and all(j['status'] in ('success','failed','manual','skipped','canceled') for j in jobs):
            completed=True
            break
        time.sleep(3)
    result={'pipeline':pipeline,'jobs':[{k:j[k] for k in ('id','name','status')} for j in jobs]}
    print(json.dumps(result),flush=True)
    with (b.STATE/'lifecycle-results.jsonl').open('a') as f:
        f.write(json.dumps(result)+'\n')
    if not completed:
        raise TimeoutError(f'Pipeline {pipeline} did not finish: {result}')
    for name in success_jobs:
        matched = [job for job in jobs if job['name'] == name]
        if len(matched) != 1 or matched[0]['status'] != 'success':
            raise AssertionError(f'{name} did not succeed: {result}')
    return jobs


def main():
    if (b.STATE/'lifecycle-project.json').exists():
        raise SystemExit('Lifecycle already initialized; inspect saved results instead of duplicating resources.')
    p=b.api('POST','/projects',{'name':'audit-lifecycle','initialize_with_readme':True,'visibility':'private','default_branch':'main','only_allow_merge_if_pipeline_succeeds':True})
    pid=p['id']; (b.STATE/'lifecycle-project.json').write_text(json.dumps({'id':pid,'path':p['path_with_namespace']}))
    seed=HERE.parent.parent/'mesh/labs/gitlab/project-seed'
    content=(seed/'.gitlab-ci.yml').read_text()
    lint=b.api('POST',f'/projects/{pid}/ci/lint',{'content':content})
    print('Seed CI lint:',json.dumps({k:lint[k] for k in ('valid','errors','warnings')}),flush=True)
    assert lint['valid']
    for tag,access,network,clone in [('mesh-deploy','ref_protected','control','https://gitlab.audit.local'),('mesh-validate','not_protected','gitnet','http://gitlab:8929')]:
        r=b.api('POST','/user/runners',{'runner_type':'project_type','project_id':pid,'description':'audit-'+tag,'tag_list':tag,'access_level':access,'run_untagged':False,'locked':True})
        cfg=f'''\n[[runners]]
 name = "audit-{tag}"
 url = "https://gitlab.audit.local"
 clone_url = "{clone}"
 token = {json.dumps(r['token'])}
 tls-ca-file = "/etc/gitlab-runner/certs/ca.crt"
 executor = "docker"
 [runners.docker]
 image = "ansible-controller:e2e"
 network_mode = "gitlab-audit_{network}"
 pull_policy = "if-not-present"
 volumes = [{json.dumps(str(b.STATE/'web-tls/ca.crt')+':/etc/gitlab-runner/certs/ca.crt:ro')}]
'''
        b.docker('exec','-i','gitlab-audit-runner-1','sh','-c','cat >> /etc/gitlab-runner/config.toml',input=cfg)
    for key,value,kind in [('CTL_SSH_KEY',b.docker('run','--rm','-v',str(b.STATE)+':/state:ro','--entrypoint','cat','ansible-controller:e2e','/state/ci-key'),'file'),('CTL_KNOWN_HOSTS',(b.STATE/'ctl-known-hosts').read_text(),'file'),('CTL_HOST','controller','env_var')]:
        b.api('POST',f'/projects/{pid}/variables',{'key':key,'value':value,'variable_type':kind,'protected':True})
    deploy=b.api('POST',f'/projects/{pid}/deploy_tokens',{'name':'audit-lifecycle-fetch','scopes':['read_repository']})
    envmap=json.loads((b.STATE/'environments.yml').read_text())
    for name,base in [('lab-direct','audit-direct'),('lab-mesh','audit-mesh')]:
        envmap['environments'][name]=dict(envmap['environments'][base],allowed_projects=[p['path_with_namespace']],inventory='inventory/direct.ini' if name=='lab-direct' else 'inventory/lab.ini')
        f=b.STATE/'fetch-secrets'/f'{name}.token'; f.write_text(deploy['username']+':'+deploy['token']+'\n'); f.chmod(0o600)
    (b.STATE/'environments.yml').write_text(json.dumps(envmap))
    # Preserve the seed pipeline verbatim; adapt fixture inventory and trust.
    # Both controllers and the node mount the same pinned public host keys.
    actions=[{'action':'create','file_path':'ansible.cfg',
        'content':'[defaults]\nhost_key_checking=True\n[ssh_connection]\nssh_args=-o UserKnownHostsFile=/known_hosts -o StrictHostKeyChecking=yes\n'}]
    for path in seed.rglob('*'):
        if path.is_file():
            rel=path.relative_to(seed).as_posix()
            value=path.read_text()
            if rel=='inventory/lab.ini': value='[lab]\nmesh-target ansible_user=ansible\n'
            actions.append({'action':'update' if rel=='README.md' else 'create','file_path':rel,'content':value})
    b.api('POST',f'/projects/{pid}/repository/commits',{'branch':'main','commit_message':'Seed actual integration workflow','actions':actions})
    time.sleep(3)
    pp=b.api('GET',f'/projects/{pid}/pipelines')[0]
    jobs=wait_jobs(pid,pp['id'])
    assert next(j for j in jobs if j['name']=='validate')['status']=='success'
    # Branch + merge request exercises unprotected, secretless validation.
    b.api('POST',f'/projects/{pid}/repository/branches',{'branch':'audit-review','ref':'main'})
    b.api('POST',f'/projects/{pid}/repository/commits',{'branch':'audit-review','commit_message':'Review fixture change','actions':[{'action':'create','file_path':'REVIEW.txt','content':'reviewed fixture change\n'}]})
    mr=b.api('POST',f'/projects/{pid}/merge_requests',{'source_branch':'audit-review','target_branch':'main','title':'Audit review and merge lifecycle'})
    finish(pid,mr)


def finish(pid,mr):
    # MR preparation is asynchronous; wait for its automatically created pipeline.
    for _ in range(40):
        candidates=b.api('GET',f"/projects/{pid}/merge_requests/{mr['iid']}/pipelines")
        if candidates: break
        time.sleep(2)
    if not candidates: raise RuntimeError('MR pipeline did not appear')
    mp=candidates[0]
    mj=wait_jobs(pid,mp['id'])
    assert all(j['name']=='validate' and j['status']=='success' for j in mj)
    b.api('PUT',f"/projects/{pid}/merge_requests/{mr['iid']}/merge",{'sha':mr['sha'],'should_remove_source_branch':True})
    time.sleep(3)
    pp=b.api('GET',f'/projects/{pid}/pipelines?ref=main')[0]
    jobs=wait_jobs(pid,pp['id'])
    job=next(j for j in jobs if j['name']=='deploy-mesh')
    b.api('POST',f"/projects/{pid}/jobs/{job['id']}/play")
    wait_jobs(pid,pp['id'], success_jobs=('deploy-mesh',))
    direct=next(j for j in jobs if j['name']=='deploy-direct')
    b.api('POST',f"/projects/{pid}/jobs/{direct['id']}/play")
    wait_jobs(pid,pp['id'], success_jobs=('deploy-direct',))
    schedule=b.api('POST',f'/projects/{pid}/pipeline_schedules',{'description':'audit mesh check','ref':'main','cron':'0 0 1 1 *','active':False})
    b.api('POST',f"/projects/{pid}/pipeline_schedules/{schedule['id']}/play")
    time.sleep(4)
    scheduled=b.api('GET',f'/projects/{pid}/pipelines?source=schedule')[0]
    wait_jobs(pid,scheduled['id'], success_jobs=('scheduled-check',))
    print('Lifecycle completed; inspect individual statuses in lifecycle-results.jsonl.',flush=True)


if __name__=='__main__': main()
