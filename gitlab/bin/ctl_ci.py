"""Controller-owned request journal and narrowly scoped artifact export.

Invoked by ctl-run under its environment lock; never installed as an SSH command.
Only the administrator chooses storage paths. The fetched project is never exported.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import sys
import tarfile
import tempfile

UUID = re.compile(r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}')
RUN_ID = re.compile(r'[0-9]{8}T[0-9]{6}Z-[0-9]+')
MESH_JOBS = Path('/var/lib/mesh/jobs')
MESH_LOGS = Path('/var/log/ansible/runner')


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def request_path(root, env, project, pipeline, playbook):
    identity = json.dumps([env, project, pipeline, playbook]).encode()
    return root / 'requests' / (hashlib.sha256(identity).hexdigest() + '.json')


def load_record(root, request, sha):
    reference = json.loads(request.read_text())
    if reference['sha'] != sha:
        raise ValueError('pipeline request already binds a different commit')
    run = reference['run_id']
    if not RUN_ID.fullmatch(run):
        raise ValueError('invalid journal run identity')
    record = json.loads((root / 'records' / (run + '.json')).read_text())
    # A crash can occur after mesh dispatch but before ctl-run records its UUID.
    # The mesh dispatcher prints tracking identity before any remote submission.
    if record['mode'] == 'mesh' and not record.get('mesh_job'):
        log = root / 'logs' / (run + '.log')
        if log.exists():
            with log.open() as stream:
                for line in stream:
                    match = re.fullmatch(r'mesh-run: tracking job=(' + UUID.pattern + r')\n?', line)
                    if match:
                        record['mesh_job'] = match[1]
                        break
    mesh_job = record.get('mesh_job')
    if mesh_job:
        if not UUID.fullmatch(mesh_job):
            raise ValueError('invalid mesh job identity')
        meta = MESH_JOBS / mesh_job / 'meta.json'
        if meta.exists():
            metadata = json.loads(meta.read_text())
            record['status'] = metadata['status']
            if metadata['status'] == 'succeeded':
                record['rc'] = '0'
            elif re.fullmatch(r'failed rc=[0-9]+', metadata['status']):
                record['rc'] = metadata['status'].split('=')[1]
    return record


def replay(root, request, sha):
    if not request.exists():
        return
    record = load_record(root, request, sha)
    # Only a recorded refusal before submission is safe to attempt again.
    if record['status'] in ('refused', 'submit-failed-pre'):
        return
    terminal = record['status'] in ('finished', 'succeeded') or bool(
        re.fullmatch(r'failed rc=[0-9]+', record['status']))
    rc = int(record['rc']) if terminal else 2
    if not 0 <= rc <= 255:
        raise ValueError('invalid recorded exit code')
    if not terminal:
        print('ctl-run: request already started; outcome unresolved. Recover original mesh job '
              + (record.get('mesh_job') or '(inspect controller records)')
              + '; refusing another execution.', file=sys.stderr)
    print(record['run_id'], rc)


def add_file(archive, path, name):
    # No links, devices, FIFOs, staging files or arbitrary caller paths.
    # Opening without following links also closes the leaf replacement race.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ValueError('artifact is not a regular file')
        member = tarfile.TarInfo(name)
        member.size = info.st_size
        member.mode = 0o600
        archive.addfile(member, stream)


def export(root, record):
    with tarfile.open(fileobj=sys.stdout.buffer, mode='w|') as archive:
        payload = json.dumps(record, indent=2).encode()
        info = tarfile.TarInfo('ctl-run.json')
        info.mode = 0o600
        info.size = len(payload)
        archive.addfile(info, io.BytesIO(payload))
        log = root / 'logs' / (record['run_id'] + '.log')
        if log.exists():
            add_file(archive, log, 'console.log')
        mesh = record.get('mesh_job')
        if not mesh:
            return
        if not UUID.fullmatch(mesh):
            raise ValueError('invalid mesh job identity')
        prefix = 'logs/runner/' + mesh + '/'
        meta = MESH_JOBS / mesh / 'meta.json'
        add_file(archive, meta, prefix + 'meta.json')
        base = MESH_LOGS / mesh
        if base.is_symlink():
            raise ValueError('artifact directory is a symlink')
        for name in ('stdout', 'rc', 'status'):
            path = base / name
            if path.exists() or path.is_symlink():
                add_file(archive, path, prefix + name)
        events = base / 'job_events'
        if events.is_symlink():
            raise ValueError('events directory is a symlink')
        if events.is_dir():
            for path in sorted(events.iterdir()):
                if path.suffix == '.json':
                    add_file(archive, path, prefix + 'job_events/' + path.name)


def main():
    if sys.argv[1] == 'collect-export':
        root = Path(sys.argv[2])
        mesh = sys.argv[3]
        if not UUID.fullmatch(mesh):
            raise ValueError('invalid mesh job identity')
        metadata = json.loads((MESH_JOBS / mesh / 'meta.json').read_text())
        export(root, {'run_id': 'collection', 'mesh_job': mesh,
                      'status': metadata['status'], 'mode': 'mesh'})
        return
    command, directory, env, project, pipeline, playbook, sha, *extra = sys.argv[1:]
    root = Path(directory)
    if not pipeline:
        raise ValueError('--pipeline is required for request tracking and artifacts')
    request = request_path(root, env, project, pipeline, playbook)
    if command == 'replay':
        replay(root, request, sha)
    elif command == 'claim':
        atomic_json(request, {'sha': sha, 'run_id': extra[0]})
    elif command == 'export':
        export(root, load_record(root, request, sha))
    else:
        raise ValueError('unknown journal command')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, json.JSONDecodeError) as error:
        print(f'ctl-run: journal/artifact error: {error}', file=sys.stderr)
        sys.exit(2)
