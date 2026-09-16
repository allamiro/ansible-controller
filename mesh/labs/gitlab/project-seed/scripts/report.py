"""Summarize controller evidence without copying task output or variables."""
import html
import json
import sys
from pathlib import Path
from xml.etree import ElementTree as ET


FIELDS = ('project', 'sha', 'commit_subject', 'env', 'mode', 'playbook', 'inventory',
          'destination', 'gitlab_pipeline', 'gitlab_job', 'sync_job', 'run_id',
          'mesh_job', 'synced_at', 'updated_at')
COUNTERS = ('ok', 'changed', 'failures', 'dark', 'skipped', 'rescued', 'ignored')


def read_json(path):
    try:
        value = path.read_text()
        result = json.loads(value)
        return result if isinstance(result, dict) else {}
    except (OSError, ValueError):
        return {}


def recap(artifacts):
    latest = None
    for path in artifacts.glob('logs/runner/*/job_events/*.json'):
        event = read_json(path)
        if event.get('event') != 'playbook_on_stats':
            continue
        counter = event.get('counter')
        if type(counter) is not int:
            continue
        if latest is None or counter > latest[0]:
            latest = (counter, event.get('event_data', {}))
    if latest is None or not isinstance(latest[1], dict):
        return None
    data = latest[1]
    totals, hosts = {}, set()
    for key in COUNTERS:
        values = data.get(key, {})
        if not isinstance(values, dict) or any(type(v) is not int or v < 0 for v in values.values()):
            return None
        totals[key] = sum(values.values())
        hosts.update(values)
    return dict(inventory_hosts=len(hosts), **totals)


def write_report(rc, directory, artifacts='mesh-artifacts', phase='execute'):
    directory, artifacts = Path(directory), Path(artifacts)
    directory.mkdir(parents=True, exist_ok=True)
    record = read_json(artifacts / 'ctl-run.json')
    channel = read_json(artifacts / 'channel.json')
    state = record.get('status', 'unavailable')
    known = state in ('finished', 'succeeded') or (
        isinstance(state, str) and state.startswith('failed rc=') and state[10:].isdigit())
    execution_rc = ('0' if state == 'succeeded' else state[10:]
                    if known and state.startswith('failed rc=') else record.get('rc') if known else None)
    # A successful channel with an unresolved controller outcome is not success.
    failed = rc != 0 or not (known and execution_rc == '0' if phase != 'sync' else state == 'synced')
    status = 'FAILED' if failed else 'SUCCEEDED'
    summary = {
        'phase': phase, 'result': status, 'channel_rc': rc,
        'controller_status': state,
        'execution_rc': execution_rc,
        'transfer_rc': channel.get('artifact_rc'),
        'metadata': {key: record[key] for key in FIELDS if isinstance(record.get(key), str)},
        'recap': recap(artifacts) if phase != 'sync' else None,
    }
    message = (f'{phase.capitalize()} channel returned exit code {rc}; controller status: {state}. '
               'Inspect restricted artifacts for details. Missing evidence does not prove success.')
    suite = ET.Element('testsuite', name='Ansible sync' if phase == 'sync' else 'Ansible deployment',
                       tests='1', failures=str(int(failed)), errors='0')
    case = ET.SubElement(suite, 'testcase', classname='automation',
                         name='Git sync and receipt transfer' if phase == 'sync' else 'Deployment and result transfer')
    if failed:
        ET.SubElement(case, 'failure', message='Operation failed or outcome unresolved').text = message
    ET.ElementTree(suite).write(directory / 'deployment.xml', encoding='utf-8', xml_declaration=True)
    rows = ''.join(f'<tr><th>{html.escape(key)}</th><td>{html.escape(value)}</td></tr>'
                   for key, value in summary['metadata'].items())
    counts = (html.escape(json.dumps(summary['recap'], sort_keys=True))
              if summary['recap'] is not None else 'No final Ansible recap available.')
    (directory / 'summary.html').write_text(
        '<!doctype html><html lang="en"><meta charset="utf-8">'
        '<title>Ansible operation result</title><body>'
        f'<h1>{phase.capitalize()} {status}</h1><p>{html.escape(message)}</p>'
        f'<table>{rows}</table><h2>Execution recap</h2><pre>{counts}</pre>'
        '<p>Counts describe inventory host names, not unique machines or license usage. '
        'JUnit contains one aggregate operation check.</p></body></html>', encoding='utf-8')
    (directory / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    return failed


if __name__ == '__main__':
    rc = int(sys.argv[1])
    if not 0 <= rc <= 255:
        raise SystemExit('Expected a shell exit code between 0 and 255')
    phase = sys.argv[2] if len(sys.argv) > 2 else 'execute'
    if phase not in ('execute', 'sync', 'collect'):
        raise SystemExit('Invalid report phase')
    failed = write_report(rc, 'reports', phase=phase)
    # deploy.sh preserves the original nonzero operation code; this catches a
    # contradictory success channel with unresolved controller evidence.
    sys.exit(2 if failed else 0)
