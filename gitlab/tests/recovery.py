"""Interrupt result streaming, then collect the original unit without resubmitting."""
import importlib.util
import json
from pathlib import Path
import threading
import subprocess
import time

s=importlib.util.spec_from_file_location('v',Path(__file__).with_name('verify.py'))
v=importlib.util.module_from_spec(s);s.loader.exec_module(v)
b=v.b

def poll(probe, description, timeout=120):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        try:
            value=probe()
            if value:
                return value
        except (subprocess.SubprocessError, OSError, json.JSONDecodeError):
            pass
        time.sleep(1)
    raise TimeoutError(description)


def running_jobs():
    raw=b.docker('exec','gitlab-audit-controller-1','python3','-c',"import glob,json,os; print(json.dumps([os.path.basename(os.path.dirname(p)) for p in glob.glob('/var/lib/mesh/jobs/*/meta.json') if json.load(open(p)).get('status')=='running']))",timeout=10)
    return json.loads(raw)


def read_meta(job):
    return json.loads(b.docker('exec','gitlab-audit-controller-1','cat',f'/var/lib/mesh/jobs/{job}/meta.json',timeout=10))


if __name__=='__main__':
    result=[]
    thread=threading.Thread(target=lambda: result.append(v.run_case('interrupted-mesh-stream','audit-mesh','playbooks/slow.yml','failed')))
    thread.start()
    job=None
    try:
        jobs=poll(running_jobs, 'No running unit appeared', timeout=60)
        assert len(jobs)==1, jobs
        job=jobs[0]
        # Exact executable match, scoped only to our disposable controller.
        b.docker('exec','gitlab-audit-controller-1','pkill','-TERM','-f','^/bin/bash /usr/local/mesh/bin/mesh-run ')
    finally:
        thread.join(timeout=240)
    assert result and result[0]['pass']
    def interrupted():
        record=read_meta(job)
        return record if record['status']=='results-incomplete' else None
    meta=poll(interrupted, 'Interrupted dispatcher did not preserve results-incomplete')
    assert meta['status']=='results-incomplete',meta['status']
    print('Preserved original unit:',job,'status:',meta['status'],flush=True)
    # Wait for the actual original unit, independent of the play's duration.
    def unit_finished():
        units=json.loads(b.docker('exec','gitlab-audit-controller-1','receptorctl',
            '--socket','/run/receptor/receptor.sock','work','list','--unit_id',meta['unit_id'],timeout=10))
        return any(unit.get('StateName') in ('Succeeded','Failed') for unit in units.values())
    poll(unit_finished, 'Original unit did not finish before collection', timeout=150)
    output=b.docker('exec','gitlab-audit-controller-1','/usr/local/lab-bin/ctl-run','--collect',job)
    after=json.loads(b.docker('exec','gitlab-audit-controller-1','cat',f'/var/lib/mesh/jobs/{job}/meta.json'))
    assert after['status']=='succeeded',after['status']
    record={'case':'collect-interrupted-original-unit','mesh_job':job,'before':meta['status'],'after':after['status'],'pass':True}
    (b.STATE/'recovery-results.json').write_text(json.dumps(record,indent=2))
    print(json.dumps(record),flush=True)
