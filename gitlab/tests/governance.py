"""Protected branch, API trigger, release tag and terminal collection checks."""
import importlib.util
import json
import secrets
import urllib.request
import urllib.error
from pathlib import Path

s=importlib.util.spec_from_file_location('l',Path(__file__).with_name('lifecycle.py'))
l=importlib.util.module_from_spec(s); s.loader.exec_module(l)
b=l.b


def main():
    pid=json.loads((b.STATE/'lifecycle-project.json').read_text())['id']
    try:
        b.api('DELETE',f'/projects/{pid}/protected_branches/main')
    except urllib.error.HTTPError as e:
        if e.code != 404: raise
    b.api('POST',f'/projects/{pid}/protected_branches',{'name':'main','push_access_level':0,'merge_access_level':40})
    u=b.api('POST','/users',{'username':'audit-developer','name':'Audit Developer','email':'audit-developer@example.invalid','password':secrets.token_urlsafe(32),'skip_confirmation':True})
    b.api('POST',f'/projects/{pid}/members',{'user_id':u['id'],'access_level':30})
    token=b.api('POST',f"/users/{u['id']}/personal_access_tokens",{'name':'audit-permission-check','scopes':['api']})
    req=urllib.request.Request(b.URL+f'/projects/{pid}/repository/commits',method='POST',headers={'PRIVATE-TOKEN':token['token'],'Content-Type':'application/json'},data=json.dumps({'branch':'main','commit_message':'Must be rejected','actions':[{'action':'create','file_path':'MUST-NOT-EXIST','content':'denied'}]}).encode())
    try:
        urllib.request.urlopen(req,timeout=30)
        raise AssertionError('Developer bypassed protected main')
    except urllib.error.HTTPError as e:
        assert e.code in (400,403),e.code
        print('Developer direct push rejected:',e.code,flush=True)
    finally:
        try:
            b.api('DELETE',f"/personal_access_tokens/{token['id']}")
        finally:
            b.api('DELETE',f"/users/{u['id']}")
    trigger=b.api('POST',f'/projects/{pid}/triggers',{'description':'audit API trigger'})
    for confirm in ('no','yes'):
        req=urllib.request.Request(b.URL+f'/projects/{pid}/trigger/pipeline',method='POST',headers={'Content-Type':'application/json'},data=json.dumps({'token':trigger['token'],'ref':'main','variables':{'DEPLOY_CONFIRM':confirm}}).encode())
        with urllib.request.urlopen(req,timeout=30) as response: p=json.load(response)
        jobs=l.wait_jobs(pid,p['id'])
        automatic=[j for j in jobs if j['name']=='api-deploy']
        assert (confirm=='no' and not automatic) or (confirm=='yes' and automatic[0]['status']=='success')
    b.api('DELETE',f"/projects/{pid}/triggers/{trigger['id']}")
    b.api('POST',f'/projects/{pid}/protected_tags',{'name':'v*','create_access_level':40})
    b.api('POST',f'/projects/{pid}/repository/tags',{'tag_name':'v-audit-1','ref':'main'})
    import time
    time.sleep(3)
    p=b.api('GET',f'/projects/{pid}/pipelines?ref=v-audit-1')[0]
    jobs=l.wait_jobs(pid,p['id'])
    job=next(j for j in jobs if j['name']=='tag-deploy')
    b.api('POST',f"/projects/{pid}/jobs/{job['id']}/play")
    jobs=l.wait_jobs(pid,p['id'])
    assert next(j for j in jobs if j['name']=='tag-deploy')['status']=='success'
    # Collect an already terminal mesh run through the actual seed CI job.
    jid=b.docker('exec','gitlab-audit-controller-1','python3','-c',"import glob,json,os; p=sorted(glob.glob('/var/lib/mesh/jobs/*/meta.json'),key=os.path.getmtime)[-1]; print(os.path.basename(os.path.dirname(p)))").strip()
    b.api('POST',f'/projects/{pid}/variables',{'key':'JOB_ID','value':jid,'protected':True})
    p=b.api('GET',f'/projects/{pid}/pipelines?ref=main')[0]
    jobs=b.api('GET',f"/projects/{pid}/pipelines/{p['id']}/jobs")
    job=next(j for j in jobs if j['name']=='collect')
    b.api('POST',f"/projects/{pid}/jobs/{job['id']}/play")
    jobs=l.wait_jobs(pid,p['id'])
    assert next(j for j in jobs if j['name']=='collect')['status']=='success'
    print('Governance, token trigger, tag release and terminal collection passed.',flush=True)


if __name__=='__main__': main()
