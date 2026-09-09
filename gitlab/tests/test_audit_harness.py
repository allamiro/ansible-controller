"""Ensure audit scripts fail on bad outcomes and keep rerun evidence separate."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location('test_audit_' + name, HERE / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AuditHarnessTests(unittest.TestCase):
    def test_failed_deployment_cannot_report_lifecycle_success(self):
        module = load('lifecycle')
        with tempfile.TemporaryDirectory() as directory, patch.object(module.b, 'STATE', Path(directory)), patch.object(module.b, 'api', return_value=[{'id': 1, 'name': 'deploy-mesh', 'status': 'failed'}]):
            with self.assertRaises(AssertionError):
                module.wait_jobs(1, 1, success_jobs=('deploy-mesh',))

    def test_nonterminal_pipeline_times_out_and_preserves_evidence(self):
        module = load('lifecycle')
        with tempfile.TemporaryDirectory() as directory, patch.object(module.b, 'STATE', Path(directory)), patch.object(module.b, 'api', return_value=[{'id': 1, 'name': 'deploy-mesh', 'status': 'running'}]), patch.object(module.time, 'monotonic', side_effect=[0, 1, 181]), patch.object(module.time, 'sleep'):
            with self.assertRaises(TimeoutError):
                module.wait_jobs(1, 1)
            self.assertTrue((Path(directory) / 'lifecycle-results.jsonl').exists())

    def test_old_failure_does_not_poison_current_verification_results(self):
        module = load('verify')
        with tempfile.TemporaryDirectory() as directory, patch.object(module.b, 'STATE', Path(directory)), patch.object(module.b, 'api', side_effect=[{'id': 1}, {'id': 1, 'status': 'success'}, []]):
            module.RESULTS = [{'pass': False}]
            module.CURRENT_RESULTS = []
            module.run_case('fixed-rerun')
            self.assertTrue(all(result['pass'] for result in module.CURRENT_RESULTS))
            self.assertEqual(len(module.RESULTS), 2)
            self.assertFalse(module.RESULTS[0]['pass'])

    def test_partial_bootstrap_refuses_before_any_external_action(self):
        module = load('bootstrap')
        with tempfile.TemporaryDirectory() as directory, patch.object(module, 'STATE', Path(directory)), patch.object(module, 'api') as api, patch.object(module, 'docker') as docker:
            (Path(directory) / 'bootstrap.started').touch()
            with self.assertRaises(SystemExit):
                module.main()
            api.assert_not_called()
            docker.assert_not_called()


if __name__ == '__main__':
    unittest.main()
