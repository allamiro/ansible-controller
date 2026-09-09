"""Journal replay and export against isolated records, never live mesh state."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import types
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('ctl_ci', Path(__file__).parents[1] / 'bin/ctl_ci.py')
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)


class JournalTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.mesh = '00000000-0000-0000-0000-000000000001'
        self.run = '20260909T120000Z-100'
        self.sha = 'a' * 40
        self.request = ci.request_path(self.root, 'prod-mesh', 'group/project', '10', 'site.yml')
        ci.atomic_json(self.request, {'sha': self.sha, 'run_id': self.run})
        self.record = {'run_id': self.run, 'mode': 'mesh', 'status': 'results-incomplete',
                       'rc': '2', 'mesh_job': self.mesh}
        ci.atomic_json(self.root / 'records' / (self.run + '.json'), self.record)
        self.jobs = self.root / 'jobs'
        self.logs = self.root / 'runner'
        self.addCleanup(patch.stopall)
        patch.object(ci, 'MESH_JOBS', self.jobs).start()
        patch.object(ci, 'MESH_LOGS', self.logs).start()

    def test_recovered_failure_replays_original_result(self):
        ci.atomic_json(self.jobs / self.mesh / 'meta.json', {'status': 'failed rc=7'})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            ci.replay(self.root, self.request, self.sha)
        self.assertEqual(out.getvalue().strip(), self.run + ' 7')

    def test_proven_presubmit_refusal_can_retry(self):
        ci.atomic_json(self.jobs / self.mesh / 'meta.json', {'status': 'submit-failed-pre'})
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            ci.replay(self.root, self.request, self.sha)
        self.assertEqual(out.getvalue(), '')

    def test_tracking_log_recovers_identity_after_dispatcher_crash(self):
        self.record.update(mesh_job='', status='started', rc='')
        ci.atomic_json(self.root / 'records' / (self.run + '.json'), self.record)
        (self.root / 'logs').mkdir()
        (self.root / 'logs' / (self.run + '.log')).write_text('mesh-run: tracking job=' + self.mesh + '\n')
        ci.atomic_json(self.jobs / self.mesh / 'meta.json', {'status': 'succeeded'})
        recovered = ci.load_record(self.root, self.request, self.sha)
        self.assertEqual(recovered['mesh_job'], self.mesh)
        self.assertEqual(recovered['rc'], '0')

    def export(self):
        output = io.BytesIO()
        with patch.object(ci.sys, 'stdout', types.SimpleNamespace(buffer=output)):
            ci.export(self.root, self.record)
        return tarfile.open(fileobj=io.BytesIO(output.getvalue()))

    def test_archive_contains_results_and_metadata_but_no_credentials(self):
        ci.atomic_json(self.jobs / self.mesh / 'meta.json', {'status': 'succeeded'})
        base = self.logs / self.mesh
        (base / 'job_events').mkdir(parents=True)
        (base / 'stdout').write_text('play output')
        (base / 'rc').write_text('0')
        (base / 'job_events/1.json').write_text('{}')
        (base / 'private-key').write_text('DO NOT EXPORT')
        with self.export() as archive:
            names = archive.getnames()
            self.assertIn('logs/runner/' + self.mesh + '/meta.json', names)
            self.assertIn('logs/runner/' + self.mesh + '/job_events/1.json', names)
            self.assertFalse(any('private-key' in name for name in names))

    def test_archive_refuses_symlink_to_secret(self):
        ci.atomic_json(self.jobs / self.mesh / 'meta.json', {'status': 'succeeded'})
        base = self.logs / self.mesh
        base.mkdir(parents=True)
        secret = self.root / 'secret'
        secret.write_text('DO NOT EXPORT')
        (base / 'stdout').symlink_to(secret)
        with self.assertRaises(OSError):
            self.export()
