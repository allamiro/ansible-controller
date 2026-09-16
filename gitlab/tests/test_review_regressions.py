"""Exercise bootstrap error paths and CI input validation without live services."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReviewRegressions(unittest.TestCase):
    def test_variable_updates_never_delete_working_value(self):
        source = (ROOT / 'gitlab/setup.sh').read_text()
        function = source[source.index('setvar() {'):source.index('\nsetvar CTL_SSH_KEY')]
        stub = '''
die() { echo "$*" >&2; exit 1; }
curl() { printf '%s' "$LOOKUP_STATUS"; }
glab() { printf '%s\\n' "$1 $2" >&2; return "$UPDATE_RC"; }
'''
        for status, update_rc, expected, succeeds in [
            ('200','0','PUT',True), ('404','0','POST',True),
            ('503','0','',False), ('403','0','',False), ('200','22','PUT',False),
        ]:
            with self.subTest(status=status, update_rc=update_rc):
                result = subprocess.run(['bash','-euc',stub+function+'\nsetvar CTL_HOST env_var value=fixture'],
                    env=dict(os.environ, LOOKUP_STATUS=status, UPDATE_RC=update_rc,
                             PID='1', STATE='/unused', GLURL='https://fixture.invalid', ENV_SCOPE='prod-*'),
                    capture_output=True,text=True)
                self.assertEqual(result.returncode == 0, succeeds, result.stderr)
                self.assertNotIn('DELETE',result.stdout + result.stderr)
                if expected: self.assertTrue(result.stderr.startswith(expected),result.stderr)
                else: self.assertEqual(result.stdout,'')

    def test_galaxy_gate_rejects_malformed_and_wrong_shaped_requirements(self):
        source = (ROOT / '.github/scripts/ansible-quality.sh').read_text()
        script = source.split("declared=$(python3 - <<'PY'\n",1)[1].split('\nPY\n)',1)[0]
        for text, success, output in [('',True,'no'), ('roles: []\ncollections: []',True,'no'),
                ('roles: [demo]',True,'yes'), ('roles: [',False,''), ('[demo]',False,''),
                ('roles: wrong',False,''), ('false',False,'')]:
            with self.subTest(text=text), tempfile.TemporaryDirectory() as directory:
                path = Path(directory)/'configs';path.mkdir()
                (path/'requirements.yml').write_text(text)
                result = subprocess.run(['python3','-c',script],cwd=directory,capture_output=True,text=True)
                self.assertEqual(result.returncode == 0, success,result.stderr)
                self.assertEqual(result.stdout.strip(),output)

    def test_runner_policy_rejects_shared_or_unlocked_registration(self):
        import json
        source = (ROOT / 'gitlab/setup.sh').read_text()
        predicate = source.split("'.paused == false",1)[1].split("' >/dev/null",1)[0]
        predicate = '.paused == false' + predicate
        base = dict(paused=False, access_level='ref_protected', locked=True,
                    run_untagged=False,tag_list=['mesh-deploy'],projects=[{'id':1}])
        for changes, accepts in [({},True), ({'locked':False},False),
                ({'projects':[{'id':1},{'id':2}]},False), ({'projects':[{'id':2}]},False)]:
            result = subprocess.run(['jq','-e','--arg','access','ref_protected','--arg','tag','mesh-deploy',
                                     '--argjson','pid','1',predicate],input=json.dumps(dict(base,**changes)),
                                    text=True,capture_output=True)
            self.assertEqual(result.returncode==0, accepts,result.stderr)

    def test_reused_lab_target_uses_its_actual_ssh_mount(self):
        import json
        source = (ROOT / 'gitlab/setup.sh').read_text()
        script = source[source.index('target_dir='):source.index('\ntimg=')]
        stub = 'docker() { printf "%s" "$MOUNTS"; }\n'
        mounts = [{'Type':'bind','Destination':'/home/ansible/.ssh','Source':'/actual/lab-target'}]
        for override, actual, expected in [('', mounts, '/actual/lab-target'),
                ('/explicit/target', [], '/explicit/target'), ('', [], None)]:
            result = subprocess.run(['bash','-euc',stub+script+'\nprintf "%s" "$target_dir"'],
                env=dict(os.environ, STATE='.gitlab-state', DIRECT_NETWORK='gitlab-lab-ctl_directnet',
                         DEMO_TARGET_SSH_DIR=override,MOUNTS=json.dumps(actual)),capture_output=True,text=True)
            if expected is None:
                self.assertNotEqual(result.returncode,0)
            else:
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(result.stdout,expected)
