"""Exercise the dispatcher up to submission with isolated transport stand-ins."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MeshStagingTests(unittest.TestCase):
    def setUp(self):
        state = ROOT / 'gitlab/tests/.state'
        state.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=state)
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.project = self.base / 'project'
        (self.project / 'playbooks').mkdir(parents=True)
        (self.project / 'playbooks/site.yml').write_text('[]\n')
        (self.project / 'roles/demo/tasks').mkdir(parents=True)
        (self.project / 'roles/demo/tasks/main.yml').write_text('[]\n')
        (self.project / 'ansible.cfg').write_text('[defaults]\nroles_path=./roles\n')
        (self.project / 'inventory.ini').write_text('localhost\n')
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        # No real Receptor or node is contacted. Capture the complete transmit
        # input, then deliberately fail submit so the test cannot dispatch work.
        programs = {
            'receptorctl': '#!/bin/sh\ncase "$3" in status) printf "Route Via\\nnode-a node-a\\n\\n";; work) cat >/dev/null; exit 1;; *) exit 2;; esac\n',
            'ansible-runner': '''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(sys.argv[2]) / 'project'
pathlib.Path(os.environ['TRANSMIT_CAPTURE']).write_text(json.dumps({
    'playbook': sys.argv[4],
    'env': json.loads((p.parent / 'env/envvars').read_text()) if (p.parent / 'env/envvars').exists() else {},
    'detached_inventory': (p.parent / 'inventory').exists(),
    'files': {str(f.relative_to(p)): f.read_text() for f in p.rglob('*') if f.is_file()}
}))
print('fixture payload')
''',
        }
        for name, source in programs.items():
            path = self.bin / name
            path.write_text(source)
            path.chmod(0o755)
        self.sock = socket.socket(socket.AF_UNIX)
        self.addCleanup(self.sock.close)
        self.sock.bind(str(self.base / 'receptor.sock'))
        self.capture = self.base / 'capture.json'

    def dispatch(self, playbook, *extra):
        return subprocess.run([
            'bash', str(ROOT / 'mesh/bin/mesh-run'), '--node', 'node-a',
            '--playbook', str(playbook), '--inventory', str(self.project / 'inventory.ini'),
            '--socket', str(self.base / 'receptor.sock'), '--jobs-dir', str(self.base / 'jobs'),
            '--log-dir', '', *extra,
        ], env=dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                    MESH_SLOTS_DIR=str(self.base / 'slots'),
                    MESH_POOLS_FILE=str(self.base / 'pools.yml'),
                    TRANSMIT_CAPTURE=str(self.capture)), capture_output=True, text=True)

    def run_fixture(self, playbook, *extra):
        (self.base / 'pools.yml').write_text('pools: {}\n')
        return self.dispatch(playbook, *extra)

    def test_full_project_and_relative_playbook_reach_transmit(self):
        result = self.run_fixture(self.project / 'playbooks/site.yml', '--project-dir', str(self.project))
        self.assertNotEqual(result.returncode, 0)  # intentional submit failure
        self.assertIn('AFTER the attempt', result.stderr)
        capture = json.loads(self.capture.read_text())
        self.assertEqual(capture['playbook'], 'playbooks/site.yml')
        self.assertIn('roles/demo/tasks/main.yml', capture['files'])
        self.assertIn('ansible.cfg', capture['files'])
        self.assertEqual(capture['env'], {'ANSIBLE_INVENTORY': 'inventory.ini'})
        self.assertFalse(capture['detached_inventory'])

    def test_file_inventory_retains_siblings_without_selecting_other_sources(self):
        (self.project / 'group_vars').mkdir()
        (self.project / 'group_vars/all.yml').write_text('marker: fixture\n')
        (self.project / 'other.ini').write_text('do-not-select\n')
        self.run_fixture(self.project / 'playbooks/site.yml', '--project-dir', str(self.project))
        capture = json.loads(self.capture.read_text())
        self.assertEqual(capture['env'], {'ANSIBLE_INVENTORY': 'inventory.ini'})
        self.assertFalse(capture['detached_inventory'])
        self.assertIn('group_vars/all.yml', capture['files'])
        self.assertIn('other.ini', capture['files'])

    def test_default_retains_playbook_directory_and_resolved_alias(self):
        alias = self.base / 'alias.yml'
        alias.symlink_to(self.project / 'playbooks/site.yml')
        self.run_fixture(alias)
        capture = json.loads(self.capture.read_text())
        self.assertEqual(capture['playbook'], 'site.yml')
        self.assertEqual(set(capture['files']), {'site.yml'})

    def test_inventory_alias_retains_plugin_suffix_and_adjacent_variables(self):
        (self.project / 'shared').mkdir()
        (self.project / 'shared/config.yml').write_text('plugin: amazon.aws.aws_ec2\n')
        (self.project / 'inventory').mkdir()
        alias = self.project / 'inventory/prod.aws_ec2.yml'
        alias.symlink_to('../shared/config.yml')
        (alias.parent / 'group_vars').mkdir()
        (alias.parent / 'group_vars/all.yml').write_text('marker: beside-alias\n')
        self.run_fixture(self.project / 'playbooks/site.yml', '--project-dir', str(self.project),
                         '--inventory', str(alias))
        capture = json.loads(self.capture.read_text())
        self.assertEqual(capture['env'], {'ANSIBLE_INVENTORY':'inventory/prod.aws_ec2.yml'})
        self.assertIn('inventory/group_vars/all.yml', capture['files'])
        self.assertIn('shared/config.yml', capture['files'])

    def test_outside_project_playbook_is_refused_before_transmit(self):
        outside = self.base / 'outside.yml'
        outside.write_text('[]\n')
        result = self.run_fixture(outside, '--project-dir', str(self.project))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('must be inside --project-dir', result.stderr)
        self.assertFalse(self.capture.exists())


if __name__ == '__main__':
    unittest.main()
