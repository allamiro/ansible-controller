"""Actual Runner transmit/worker contract; all tasks stay inside this container."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(shutil.which('ansible-runner'), 'requires mesh image runtime')
class RunnerInventoryTests(unittest.TestCase):
    def test_project_file_keeps_variables_and_excludes_other_inventory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'source'
            inventory = source / 'project/inventory'
            (inventory / 'group_vars').mkdir(parents=True)
            (source / 'project/playbooks').mkdir()
            (source / 'env').mkdir()
            (inventory / 'prod.ini').write_text('[deployment]\nlocalhost ansible_connection=local\n')
            (inventory / 'other.ini').write_text('[deployment]\nmust-not-run.example.invalid\n')
            (inventory / 'group_vars/all.yml').write_text('inventory_marker: adjacent\n')
            (source / 'project/playbooks/site.yml').write_text('''- hosts: deployment
  gather_facts: false
  tasks:
    - ansible.builtin.assert:
        that:
          - inventory_marker == 'adjacent'
          - groups['deployment'] == ['localhost']
''')
            (source / 'env/envvars').write_text(json.dumps({'ANSIBLE_INVENTORY':'inventory/prod.ini'}))
            env = dict(os.environ, ANSIBLE_CONFIG='/missing-test-config', ANSIBLE_NOCOLOR='1')
            transmit = subprocess.run(['ansible-runner','transmit',str(source),'-p','playbooks/site.yml'],env=env,capture_output=True,check=True)
            header = json.loads(transmit.stdout.splitlines()[0])
            self.assertFalse(header['kwargs'].get('inventory'))
            worker = root / 'worker'
            result = subprocess.run(['ansible-runner','worker','--private-data-dir',str(worker)],input=transmit.stdout,
                                    env=env,capture_output=True,timeout=60)
            self.assertEqual(result.returncode,0,result.stderr.decode())
            codes = list((worker / 'artifacts').glob('*/rc'))
            self.assertEqual(len(codes),1)
            self.assertEqual(codes[0].read_text().strip(),'0',result.stdout[-4000:])


if __name__ == '__main__':
    unittest.main()
