"""Non-secret SSH environment persistence, without changing host configuration."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('controller_env', Path(__file__).parents[1] / 'controller-env.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class EnvironmentTests(unittest.TestCase):
    def test_preserves_explicit_paths_and_unrelated_environment(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'etc').mkdir()
            (root / 'etc/environment').write_text('OTHER=value\nANSIBLE_CONFIG="/old"\n')
            values = {'ANSIBLE_CONFIG': '/site with spaces/ansible.cfg',
                      'CONTROLLER_CONFIG_DIR': '/dependencies', 'ANSIBLE_VAULT_PASSWORD': 'do-not-copy'}
            module.configure(values, root)
            pam = (root / 'etc/environment').read_text()
            self.assertIn('OTHER=value', pam)
            self.assertIn('ANSIBLE_CONFIG="/site with spaces/ansible.cfg"', pam)
            self.assertNotIn('do-not-copy', pam)
            shell = root / 'etc/profile.d/ansible-controller.sh'
            result = subprocess.check_output(['sh', '-c', '. "$1"; printf "%s" "$ANSIBLE_CONFIG"', 'sh', str(shell)], env={'PATH':os.defpath}, text=True)
            self.assertEqual(result, values['ANSIBLE_CONFIG'])
            module.configure({}, root)
            self.assertNotIn('ANSIBLE_CONFIG=', (root / 'etc/environment').read_text())

    def test_rejects_ambiguous_values_before_writing(self):
        for value in ('relative.cfg', '/site\nOTHER=value', '/site"bad', '/site/$HOME'):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(ValueError):
                    module.configure({'ANSIBLE_CONFIG':value}, Path(directory))
                self.assertEqual(list(Path(directory).iterdir()), [])
