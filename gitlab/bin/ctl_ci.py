"""Controller-owned request journal and narrowly scoped artifact export.

Journal mutations run under ctl-run's environment lock; exports are read-only.
Never installed as an SSH command.
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
# Same location ctl-run guards and dispatches against; see its CTL_RUN_MESH_JOBS.
# `or` rather than a get() default: ctl-run uses ${VAR:-...}, which treats an
# empty value as unset. Diverging here would point replay and artifact export at
# Path('.') while the guard still blocks on the real directory.
MESH_JOBS = Path(os.environ.get('CTL_RUN_MESH_JOBS') or '/var/lib/mesh/jobs')
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


def tree_digest(root):
    """Bind approval to staged bytes, link targets and executable permissions."""
    if root.is_symlink() or not root.is_dir():
        raise ValueError('synced tree is missing or replaced')
    digest = hashlib.sha256()
    digest.update(str(root.stat().st_mode).encode() + b'\0')
    def fail(error):
        raise error

    for directory, dirs, files in os.walk(root, followlinks=False, onerror=fail):
        dirs.sort()
        for name in sorted(dirs + files):
            path = Path(directory) / name
            info = path.lstat()
            digest.update(json.dumps([str(path.relative_to(root)), info.st_mode]).encode() + b'\0')
            if stat.S_ISLNK(info.st_mode):
                digest.update(os.readlink(path).encode() + b'\0')
            elif stat.S_ISREG(info.st_mode):
                digest.update(str(info.st_size).encode() + b'\0')
                with path.open('rb') as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b''):
                        digest.update(block)
            elif not stat.S_ISDIR(info.st_mode):
                raise ValueError('unsupported file in synced tree')
    return digest.hexdigest()


def sync_record(root, request, sha, env, config):
    receipt = root / 'syncs' / request.name
    if not receipt.exists():
        return None
    data = json.loads(receipt.read_text())
    record = data['record']
    if record['sha'] != sha:
        raise ValueError('synced request binds a different commit; use a new pipeline')
    if data['config'] != json.loads(config):
        raise ValueError('environment configuration changed since sync; use a new pipeline')
    if not RUN_ID.fullmatch(record['run_id']):
        raise ValueError('invalid synced run identity')
    stage = root / env / sha / record['run_id']
    if tree_digest(stage) != data['digest']:
        raise ValueError('synced tree changed; refusing execution, use a new pipeline')
    return record


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
        if record.get('status') == 'synced':
            return
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


def collection_record(root, mesh, env, project):
    """Require controller-owned provenance, including crash-before-link records."""
    if not UUID.fullmatch(mesh):
        raise ValueError('invalid mesh job identity')
    for path in (root / 'records').glob('*.json'):
        record = json.loads(path.read_text())
        if (record.get('env'), record.get('project'), record.get('mode')) != (env, project, 'mesh'):
            continue
        run = record.get('run_id', '')
        if not RUN_ID.fullmatch(run):
            raise ValueError('invalid controller run identity')
        recorded_mesh = record.get('mesh_job')
        if not recorded_mesh:
            log = root / 'logs' / (run + '.log')
            if log.exists():
                with log.open() as stream:
                    recorded_mesh = next((match[1] for line in stream
                        if (match := re.fullmatch(r'mesh-run: tracking job=(' + UUID.pattern + r')\n?', line))), '')
        if recorded_mesh == mesh:
            metadata = json.loads((MESH_JOBS / mesh / 'meta.json').read_text())
            record.update(mesh_job=mesh, status=metadata['status'])
            if metadata['status'] == 'succeeded':
                record['rc'] = '0'
            elif re.fullmatch(r'failed rc=[0-9]+', metadata['status']):
                record['rc'] = metadata['status'].split('=')[1]
            return record
    raise ValueError('mesh job is not linked to this project and environment')


def main():
    if sys.argv[1] in ('collect-check', 'collect-export'):
        root = Path(sys.argv[2])
        record = collection_record(root, *sys.argv[3:6])
        if sys.argv[1] == 'collect-export':
            export(root, record)
        return
    command, directory, env, project, pipeline, playbook, sha, *extra = sys.argv[1:]
    root = Path(directory)
    if not pipeline:
        raise ValueError('--pipeline is required for request tracking and artifacts')
    request = request_path(root, env, project, pipeline, playbook)
    if command == 'replay':
        replay(root, request, sha)
    elif command == 'sync-load':
        record = sync_record(root, request, sha, env, extra[0])
        if record is not None:
            print(json.dumps(record))
    elif command == 'sync-save':
        run = extra[1]
        if not RUN_ID.fullmatch(run):
            raise ValueError('invalid synced run identity')
        record = json.loads((root / 'records' / (run + '.json')).read_text())
        atomic_json(root / 'syncs' / request.name, {
            'record': record, 'config': json.loads(extra[0]),
            'digest': tree_digest(root / env / sha / run),
        })
    elif command == 'sync-export':
        # A sync receipt contains no playbook output or execution claim.
        record = sync_record(root, request, sha, env, extra[0])
        if record is None:
            raise ValueError('no completed sync for this request')
        export(root, record)
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
