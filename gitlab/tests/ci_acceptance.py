"""Manual release, real mesh results in GitLab artifacts, and safe job Retry.

Run after bootstrap.py, only against the dedicated gitlab-audit fixture.
Updates that fixture's project to the current reference pipeline.
"""
import io
from datetime import date, timedelta
import json
from pathlib import Path
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

import yaml
import bootstrap as b

ROOT = Path(__file__).resolve().parents[2]


def wait_job(pid, pipeline, name, states):
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        jobs = b.api('GET', f'/projects/{pid}/pipelines/{pipeline}/jobs')
        job = next((job for job in jobs if job['name'] == name), None)
        if job and job['status'] in states:
            return job
        if job and job['status'] in ('failed', 'canceled') and job['status'] not in states:
            raise AssertionError(f'{name}: unexpected {job["status"]}; job={job["id"]}')
        time.sleep(3)
    raise AssertionError(f'{name}: timeout waiting for {states}; last job={job}')


def artifacts(pid, job):
    request = urllib.request.Request(b.URL + f'/projects/{pid}/jobs/{job}/artifacts',
        headers={'PRIVATE-TOKEN': (b.STATE / 'pat').read_text().strip()})
    with urllib.request.urlopen(request, timeout=30) as response:
        archive = zipfile.ZipFile(io.BytesIO(response.read()))
    record = json.loads(archive.read('mesh-artifacts/ctl-run.json'))
    meta_path = f'mesh-artifacts/logs/runner/{record["mesh_job"]}/meta.json'
    metadata = json.loads(archive.read(meta_path))
    return record, metadata, archive.namelist()


def permissions_and_collection(pid, result):
    username = 'issue94-reviewer-' + secrets.token_hex(4)
    user = b.api('POST', '/users', {'username': username, 'name': 'Issue 94 reviewer',
        'email': username + '@example.invalid', 'password': secrets.token_urlsafe(24),
        'skip_confirmation': True})
    b.api('POST', f'/projects/{pid}/members', {'user_id': user['id'], 'access_level': 30})
    token = b.api('POST', f'/users/{user["id"]}/personal_access_tokens',
                 {'name': 'issue94-permission-test', 'scopes': ['api'],
                  'expires_at': (date.today() + timedelta(days=1)).isoformat()})['token']

    def as_user(method, path):
        request = urllib.request.Request(b.URL + path, method=method,
            headers={'PRIVATE-TOKEN': token}, data=b'' if method == 'POST' else None)
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read()

    try:
        candidate = b.api('POST', f'/projects/{pid}/pipeline', {'ref': 'main'})
        wait_job(pid, candidate['id'], 'validate', {'success'})
        manual = wait_job(pid, candidate['id'], 'deploy-mesh', {'manual'})
        for method, path in (
            ('POST', f'/projects/{pid}/jobs/{manual["id"]}/play'),
            ('GET', f'/projects/{pid}/jobs/{result["job"]}/artifacts')):
            try:
                as_user(method, path)
            except urllib.error.HTTPError as error:
                assert error.code in (403, 404), error.code
            else:
                raise AssertionError('Developer unexpectedly authorized: ' + path)
        b.api('PUT', f'/projects/{pid}/members/{user["id"]}', {'access_level': 40})
        as_user('POST', f'/projects/{pid}/jobs/{manual["id"]}/play')
        released = wait_job(pid, candidate['id'], 'deploy-mesh', {'success'})
        archive = zipfile.ZipFile(io.BytesIO(as_user('GET', f'/projects/{pid}/jobs/{released["id"]}/artifacts')))
        assert 'mesh-artifacts/ctl-run.json' in archive.namelist()
        collector = wait_job(pid, result['pipeline'], 'collect', {'manual'})
        b.api('POST', f'/projects/{pid}/jobs/{collector["id"]}/play',
              {'job_variables_attributes': [{'key': 'JOB_ID', 'value': result['mesh_job']}]})
        collected = wait_job(pid, result['pipeline'], 'collect', {'success'})
        record, metadata, _ = artifacts(pid, collected['id'])
        assert record['mesh_job'] == result['mesh_job']
        assert metadata['status'] == 'succeeded'
        result.update(developer_release_denied=True, developer_download_denied=True,
                      maintainer_release_job=released['id'], collect_job=collected['id'])
    finally:
        as_user('DELETE', '/personal_access_tokens/self')


def main():
    project = json.loads((b.STATE / 'project.json').read_text())
    pid = project['id']
    seed = ROOT / 'mesh/labs/gitlab/project-seed'
    pipeline = yaml.safe_load((seed / '.gitlab-ci.yml').read_text())
    for name in ('deploy-direct', 'scheduled-check', 'api-deploy', 'tag-deploy'):
        pipeline.pop(name)
    pipeline['validate']['tags'] = ['audit-deploy']
    pipeline['.ctl-ssh']['tags'] = ['audit-deploy']
    pipeline['variables'] = {'CTL_HOST': 'controller'}
    # The fixture's protected variable scope is '*' and its controller map uses
    # audit-mesh. Keep the actual reference commands, gate and artifacts policy.
    rendered = yaml.safe_dump(pipeline, sort_keys=False).replace('lab-mesh', 'audit-mesh')
    play = '''- name: Count actual executions
  hosts: all
  gather_facts: false
  tasks:
    - name: Append one execution marker
      ansible.builtin.command:
        argv: [/usr/bin/tee, -a, /home/ansible/issue94-runs]
        stdin: execution
      changed_when: true
'''
    contents = {'.gitlab-ci.yml': rendered,
                'scripts/ctl-ci.sh': (seed / 'scripts/ctl-ci.sh').read_text(),
                'playbooks/site.yml': play,
                'playbooks/fail.yml': '- name: Exercise failure\n  hosts: all\n  gather_facts: false\n  tasks:\n    - name: Fail deliberately\n      ansible.builtin.fail:\n        msg: intentional audit failure\n',
                'playbooks/slow.yml': '- name: Exercise waiting\n  hosts: all\n  gather_facts: false\n  tasks:\n    - name: Wait for recovery test\n      ansible.builtin.command: sleep 25\n      changed_when: false\n',
                'playbooks/ping.yml': (seed / 'playbooks/ping.yml').read_text(),
                'inventory/lab.ini': 'mesh-target ansible_user=ansible\n'}
    actions = []
    for name, content in contents.items():
        try:
            b.api('GET', f'/projects/{pid}/repository/files/' + urllib.parse.quote(name, safe='') + '?ref=main')
            action = 'update'
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
            action = 'create'
        actions.append({'action': action, 'file_path': name, 'content': content})
    commit = b.api('POST', f'/projects/{pid}/repository/commits',
                   {'branch': 'main', 'commit_message': 'Verify issue 94 reference workflow', 'actions': actions})
    # No automatic deployment is allowed while waiting for the manual gate.
    pipelines = b.api('GET', f'/projects/{pid}/pipelines?sha={commit["id"]}')
    deadline = time.monotonic() + 60
    while not pipelines and time.monotonic() < deadline:
        time.sleep(2)
        pipelines = b.api('GET', f'/projects/{pid}/pipelines?sha={commit["id"]}')
    assert pipelines, 'push did not create a pipeline'
    pipeline_id = pipelines[0]['id']
    wait_job(pid, pipeline_id, 'validate', {'success'})
    manual = wait_job(pid, pipeline_id, 'deploy-mesh', {'manual'})
    before = b.docker('exec', 'gitlab-audit-mesh-target-1', 'sh', '-c',
                      'wc -l < /home/ansible/issue94-runs 2>/dev/null || echo 0').strip()
    b.api('POST', f'/projects/{pid}/jobs/{manual["id"]}/play')
    deployed = wait_job(pid, pipeline_id, 'deploy-mesh', {'success'})
    original, metadata, files = artifacts(pid, deployed['id'])
    assert metadata['status'] == 'succeeded', metadata
    assert original['sha'] == commit['id']
    assert any(name.endswith('/stdout') for name in files), files
    after = b.docker('exec', 'gitlab-audit-mesh-target-1', 'sh', '-c',
                     'wc -l < /home/ansible/issue94-runs').strip()
    assert int(after) == int(before) + 1, (before, after)
    b.api('POST', f'/projects/{pid}/jobs/{deployed["id"]}/retry')
    retried = wait_job(pid, pipeline_id, 'deploy-mesh', {'success'})
    replayed, _, _ = artifacts(pid, retried['id'])
    assert retried['id'] != deployed['id']
    assert replayed['run_id'] == original['run_id']
    assert replayed['mesh_job'] == original['mesh_job']
    count = b.docker('exec', 'gitlab-audit-mesh-target-1', 'sh', '-c',
                     'wc -l < /home/ansible/issue94-runs').strip()
    assert count == after, 'Retry executed the playbook again'
    # A new pipeline deliberately chooses a failing playbook; artifacts must
    # survive failure and its Retry must retain the same failed execution.
    failure = b.api('POST', f'/projects/{pid}/pipeline', {'ref': 'main', 'variables': [
        {'key': 'PLAYBOOK', 'value': 'playbooks/fail.yml'}]})
    wait_job(pid, failure['id'], 'validate', {'success'})
    job = wait_job(pid, failure['id'], 'deploy-mesh', {'manual'})
    b.api('POST', f'/projects/{pid}/jobs/{job["id"]}/play')
    failed = wait_job(pid, failure['id'], 'deploy-mesh', {'failed'})
    failed_record, failed_meta, _ = artifacts(pid, failed['id'])
    assert failed_meta['status'].startswith('failed rc='), failed_meta
    b.api('POST', f'/projects/{pid}/jobs/{failed["id"]}/retry')
    failed_retry = wait_job(pid, failure['id'], 'deploy-mesh', {'failed'})
    repeated, _, _ = artifacts(pid, failed_retry['id'])
    assert failed_retry['id'] != failed['id']
    assert repeated['run_id'] == failed_record['run_id']
    result = {'pass': True, 'project': project['path'], 'sha': commit['id'],
              'pipeline': pipeline_id, 'job': deployed['id'], 'retry_job': retried['id'],
              'mesh_job': original['mesh_job'], 'failure_pipeline': failure['id'],
              'failure_job': failed['id'], 'failure_retry_job': failed_retry['id']}
    permissions_and_collection(pid, result)
    (b.STATE / 'ci-acceptance.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
