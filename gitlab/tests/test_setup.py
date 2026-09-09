"""Bootstrap failures and configuration generation without network or Docker."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]


class SetupTests(unittest.TestCase):
    def setUp(self):
        state = ROOT / 'gitlab/tests/.state'
        state.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=state)
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.state = self.base / 'gitlab/.gitlab-state'
        self.state.mkdir(parents=True)
        self.pat = self.state / 'pat'
        self.pat.write_text('unused-test-token\n')
        for name in ('setup.sh', 'environments.example.yml'):
            shutil.copy(ROOT / 'gitlab' / name, self.base / 'gitlab' / name)
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        curl = self.bin / 'curl'
        curl.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
url = next(a for a in args if a.startswith('http'))
method = args[args.index('-X') + 1] if '-X' in args else 'GET'
with open(os.environ['API_CALLS'], 'a') as log:
    log.write(method + ' ' + url + chr(10))
if url.endswith('/protected_branches/main'):
    policy = {'name': 'main', 'push_access_levels': [{'access_level': 0}],
              'merge_access_levels': [{'access_level': 40}], 'allow_force_push': False}
    if os.environ.get('POLICY_DRIFT'):
        policy['allow_force_push'] = True
    print(json.dumps(policy))
    if '-w' in args:
        print('200')
    sys.exit(0)
if url.endswith('/personal_access_tokens/self'):
    sys.exit(int(os.environ.get('DELETE_RC', '0')))
if url.endswith('/deploy_tokens'):
    # Stop after the generated map, before any runtime wiring or credentials.
    sys.exit(22)
allowed = {('GET', '/api/v4/user'), ('GET', '/api/v4/projects/platform%2Fautomation'),
           ('PUT', '/api/v4/projects/1'), ('GET', '/api/v4/projects/1/protected_tags/v%2A')}
from urllib.parse import urlsplit
if (method, urlsplit(url).path) not in allowed:
    sys.exit('Unexpected API route: ' + method + ' ' + url)
print('{"id": 1}')
''')
        curl.chmod(0o755)
        # Tripwire: even a fixture regression must never invoke real Docker.
        docker = self.bin / 'docker'
        docker.write_text('#!/bin/sh\nexit 99\n')
        docker.chmod(0o755)
        self.calls = self.base / 'api-calls'
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        API_CALLS=str(self.calls))

    def run_setup(self, **env):
        return subprocess.run(['bash', str(self.base / 'gitlab/setup.sh'),
                               'http://fixture.invalid', 'platform/automation'],
                              env=dict(self.env, **env), capture_output=True, text=True)

    def test_failed_revocation_retains_pat_and_reports_failure(self):
        result = self.run_setup(REVOKE_BOOTSTRAP='1', DELETE_RC='22')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PAT revocation failed', result.stderr)
        self.assertEqual(self.pat.read_text(), 'unused-test-token\n')
        self.assertTrue((self.state / '.curl-auth').is_file())
        self.assertEqual((self.state / '.curl-auth').stat().st_mode & 0o777, 0o600)

    def test_successful_revocation_removes_local_credentials(self):
        result = self.run_setup(REVOKE_BOOTSTRAP='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.pat.exists())
        self.assertFalse((self.state / '.curl-auth').exists())

    def test_matching_branch_protection_is_never_removed(self):
        self.run_setup(REVOKE_BOOTSTRAP='0')
        calls = self.calls.read_text().splitlines()
        protection_calls = [call for call in calls if '/protected_branches' in call]
        self.assertEqual(len(protection_calls), 2)
        self.assertTrue(all(call.startswith('GET ') for call in protection_calls))

    def test_drifted_branch_protection_is_preserved_and_setup_refuses(self):
        result = self.run_setup(REVOKE_BOOTSTRAP='0', POLICY_DRIFT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('main protection differs', result.stderr)
        self.assertNotIn('DELETE ', self.calls.read_text())
        self.assertFalse((self.state / 'environments.yml').exists())

    def test_custom_project_is_used_in_generated_allowlists(self):
        result = self.run_setup(REVOKE_BOOTSTRAP='0')
        self.assertNotEqual(result.returncode, 0)  # fixture stops at token creation
        config = yaml.safe_load((self.state / 'environments.yml').read_text())
        self.assertTrue(config['environments'])
        for environment in config['environments'].values():
            self.assertEqual(environment['allowed_projects'], ['platform/automation'])


if __name__ == '__main__':
    unittest.main()
