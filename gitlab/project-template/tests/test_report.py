import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from xml.etree import ElementTree as ET

spec = importlib.util.spec_from_file_location('report', Path(__file__).resolve().parents[1] / 'scripts/report.py')
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


class ReportTests(unittest.TestCase):
    def test_recap_metadata_escaping_and_no_task_secrets(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            artifacts = base / 'artifacts'
            events = artifacts / 'logs/runner/job/job_events'
            events.mkdir(parents=True)
            (artifacts / 'ctl-run.json').write_text(json.dumps({
                'status': 'succeeded', 'rc': '0', 'sha': 'a' * 40,
                'commit_subject': '<script>alert(1)</script>', 'env': 'prod-mesh',
                'stage_dir': 'PRIVATE PATH',
            }))
            (events / '1.json').write_text(json.dumps({'event': 'runner_on_ok',
                'counter': 1, 'event_data': {'res': {'secret': 'NEVER EXPORT'}}}))
            (events / '9.json').write_text(json.dumps({'event': 'playbook_on_stats',
                'counter': 9, 'event_data': {'ok': {'a': 5, 'b': 3}, 'changed': {'a': 2},
                                          'failures': {'a': 0, 'b': 0}, 'dark': {'b': 0}}}))
            self.assertFalse(report.write_report(0, base / 'reports', artifacts))
            summary = json.loads((base / 'reports/summary.json').read_text())
            self.assertEqual(summary['recap']['inventory_hosts'], 2)
            self.assertEqual(summary['recap']['ok'], 8)
            self.assertEqual(summary['recap']['changed'], 2)
            html = (base / 'reports/summary.html').read_text()
            self.assertIn('&lt;script&gt;', html)
            self.assertNotIn('<script>', html)
            for path in (base / 'reports').iterdir():
                self.assertNotIn('NEVER EXPORT', path.read_text())
                self.assertNotIn('PRIVATE PATH', path.read_text())

    def test_unknown_outcome_and_transfer_failure_are_distinct(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            for state, rc, expected_execution in (
                    ('submit-ambiguous', 0, None), ('results-incomplete', 2, None),
                    ('succeeded', 2, '0'), ('failed rc=7', 7, '7'), ('failed rc=7', 0, '7')):
                with self.subTest(state=state):
                    (base / 'ctl-run.json').write_text(json.dumps({'status': state,
                        'rc': '7' if state == 'failed rc=7' else '0'}))
                    self.assertTrue(report.write_report(rc, base / 'reports', base))
                    summary = json.loads((base / 'reports/summary.json').read_text())
                    self.assertEqual(summary['execution_rc'], expected_execution)
                    self.assertEqual(summary['controller_status'], state)

    def test_missing_evidence_cannot_report_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertTrue(report.write_report(0, Path(tmp) / 'reports', tmp))

    def test_transfer_failure_keeps_successful_channel_and_playbook_codes(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / 'ctl-run.json').write_text('{"status":"succeeded","rc":"0"}')
            (base / 'channel.json').write_text('{"execution_channel_rc":0,"artifact_rc":23}')
            self.assertTrue(report.write_report(2, base / 'reports', base))
            summary = json.loads((base / 'reports/summary.json').read_text())
            self.assertEqual(summary['operation_rc'], 2)
            self.assertEqual(summary['execution_channel_rc'], 0)
            self.assertEqual(summary['execution_rc'], '0')
            self.assertEqual(summary['transfer_rc'], 23)
            html = (base / 'reports/summary.html').read_text()
            self.assertIn('SSH operation exit code</th><td>0', html)
            self.assertIn('Artifact transfer exit code</th><td>23', html)

    def test_sync_report_does_not_claim_execution(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / 'ctl-run.json').write_text('{"status":"synced","rc":"0"}')
            self.assertFalse(report.write_report(0, base / 'reports', base, 'sync'))
            summary = json.loads((base / 'reports/summary.json').read_text())
            self.assertEqual(summary['phase'], 'sync')
            self.assertIsNone(summary['execution_rc'])
            self.assertIsNone(summary['recap'])

    def test_success_and_failures(self):
        for rc in (0, 2, 4, 124, 255):
            with self.subTest(rc=rc), tempfile.TemporaryDirectory() as tmp:
                (Path(tmp) / 'ctl-run.json').write_text(json.dumps({'status': 'finished', 'rc': str(rc)}))
                report.write_report(rc, tmp, tmp)
                root = ET.parse(Path(tmp) / 'deployment.xml').getroot()
                self.assertEqual(root.attrib['failures'], str(int(rc != 0)))
                self.assertEqual(len(root.findall('testcase')), 1)
                self.assertEqual(root.find('testcase/failure') is not None, rc != 0)
                html = (Path(tmp) / 'summary.html').read_text()
                self.assertIn('FAILED' if rc else 'SUCCEEDED', html)
                self.assertNotIn('<script', html)

class WrapperTests(unittest.TestCase):
    def test_preserves_execution_and_report_failures(self):
        import shutil
        import subprocess
        source = Path(__file__).resolve().parents[1] / 'scripts'
        for execution_rc, break_report, expected in ((0, False, 0), (4, False, 4), (0, True, 2), (124, True, 124)):
            with self.subTest(execution_rc=execution_rc, break_report=break_report), tempfile.TemporaryDirectory() as tmp:
                scripts = Path(tmp) / 'scripts'
                scripts.mkdir()
                shutil.copy(source / 'deploy.sh', scripts)
                shutil.copy(source / 'report.py', scripts)
                (scripts / 'ctl-ci.sh').write_text(
                    'mkdir -p mesh-artifacts\n'
                    + 'printf \'{"status":"finished","rc":"0"}\' > mesh-artifacts/ctl-run.json\n'
                    + f'exit {execution_rc}\n')
                if break_report:
                    (scripts / 'report.py').write_text('raise SystemExit(1)\n')
                result = subprocess.run(['bash', 'scripts/deploy.sh'], cwd=tmp, capture_output=True)
                self.assertEqual(result.returncode, expected)


if __name__ == "__main__":
    unittest.main()
