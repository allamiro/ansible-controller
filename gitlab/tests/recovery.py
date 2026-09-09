"""Interrupt result streaming, then collect the original unit without resubmitting."""
import importlib.util
import json
from pathlib import Path
import threading
import time

s=importlib.util.spec_from_file_location('v',Path(__file__).with_name('verify.py'))
v=importlib.util.module_from_spec(s);s.loader.exec_module(v)
b=v.b

if __name__=='__main__':
    result=[]
    thread=threading.Thread(target=lambda: result.append(v.run_case('interrupted-mesh-stream','audit-mesh','playbooks/slow.yml','failed')))
    thread.start()
    job=None
    try:
        for _ in range(60):
            raw=b.docker('exec','gitlab-audit-controller-1','python3','-c',"import glob,json,os; print(json.dumps([os.path.basename(os.path.dirname(p)) for p in glob.glob('/var/lib/mesh/jobs/*/meta.json') if json.load(open(p)).get('status')=='running']))")
            jobs=json.loads(raw)
            if jobs:
                assert len(jobs)==1
                job=jobs[0]; break
            time.sleep(1)
        assert job,'No running unit appeared'
        time.sleep(3)
        # Exact executable match, scoped only to our disposable controller.
        b.docker('exec','gitlab-audit-controller-1','pkill','-TERM','-f','^/bin/bash /usr/local/mesh/bin/mesh-run ')
    finally:
        thread.join(timeout=240)
    assert result and result[0]['pass']
    meta=json.loads(b.docker('exec','gitlab-audit-controller-1','cat',f'/var/lib/mesh/jobs/{job}/meta.json'))
    assert meta['status']=='results-incomplete',meta['status']
    print('Preserved original unit:',job,'status:',meta['status'],flush=True)
    # The remote play sleeps for 25s. Collection attaches to the same unit.
    time.sleep(28)
    output=b.docker('exec','gitlab-audit-controller-1','/usr/local/lab-bin/ctl-run','--collect',job)
    after=json.loads(b.docker('exec','gitlab-audit-controller-1','cat',f'/var/lib/mesh/jobs/{job}/meta.json'))
    assert after['status']=='succeeded',after['status']
    record={'case':'collect-interrupted-original-unit','mesh_job':job,'before':meta['status'],'after':after['status'],'pass':True}
    (b.STATE/'recovery-results.json').write_text(json.dumps(record,indent=2))
    print(json.dumps(record),flush=True)
