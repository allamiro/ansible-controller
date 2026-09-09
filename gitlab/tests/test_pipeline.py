"""Check the seed deployment command against a real local Runner-style checkout."""
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[2]


class PipelineTests(unittest.TestCase):
    def test_trigger_overrides_cannot_select_a_different_commit(self):
        state = ROOT / 'gitlab/tests/.state'
        state.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=state) as directory:
            repo = Path(directory)
            subprocess.run(['git', 'init', '-q', '-b', 'main', str(repo)], check=True)
            subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Test',
                            '-c', 'user.email=test@example.invalid', 'commit',
                            '-qm', 'protected checkout', '--allow-empty'], check=True)
            sha = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
            (repo / 'key').write_text('unused fixture')
            (repo / 'scripts').mkdir()
            shutil.copy(ROOT / 'mesh/labs/gitlab/project-seed/scripts/ctl-ci.sh', repo / 'scripts')
            (repo / 'ssh').write_text('''#!/usr/bin/env python3
import io, json, os, sys, tarfile
if '--artifacts' in sys.argv:
    with tarfile.open(fileobj=sys.stdout.buffer, mode='w|') as archive:
        info = tarfile.TarInfo('ctl-run.json')
        info.size = 2
        archive.addfile(info, io.BytesIO(b'{}'))
else:
    open(os.environ['SSH_ARGS'], 'w').write(json.dumps(sys.argv[1:]))
''')
            (repo / 'ssh').chmod(0o755)
            pipeline = yaml.safe_load((ROOT / 'mesh/labs/gitlab/project-seed/.gitlab-ci.yml').read_text())
            script = '\n'.join(pipeline['.ctl-ssh']['before_script'] + pipeline['api-deploy']['script'])
            result = subprocess.run(['bash', '-euc', script], cwd=repo,
                env=dict(os.environ, PATH=str(repo) + os.pathsep + os.environ['PATH'],
                         CTL_SSH_KEY=str(repo / 'key'), CTL_KNOWN_HOSTS='unused',
                         CI_COMMIT_SHA='a' * 40, CTL_COMMIT_SHA='b' * 40,
                         CI_PROJECT_DIR='/untrusted/override', CI_PROJECT_PATH='group/project',
                         CI_PIPELINE_ID='1', CI_JOB_ID='2', PLAYBOOK='playbooks/site.yml',
                         SSH_ARGS=str(repo / 'ssh-args')), capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            args = json.loads((repo / 'ssh-args').read_text())
            self.assertEqual(args[args.index('--sha') + 1], sha)
            self.assertTrue((repo / 'mesh-artifacts/ctl-run.json').exists())

    def test_every_deployment_route_requires_manual_release_and_artifacts(self):
        pipeline = yaml.safe_load((ROOT / 'mesh/labs/gitlab/project-seed/.gitlab-ci.yml').read_text())
        for name in ('deploy-mesh', 'deploy-direct', 'scheduled-check', 'api-deploy', 'tag-deploy'):
            job = pipeline[name]
            self.assertEqual(job['extends'], '.ctl-ssh')
            self.assertTrue(all(rule.get('when') == 'manual' for rule in job['rules']), name)
        self.assertEqual(pipeline['.ctl-ssh']['artifacts']['when'], 'always')
        self.assertEqual(pipeline['.ctl-ssh']['artifacts']['access'], 'maintainer')

    def test_export_failure_never_masks_execution_failure(self):
        state = ROOT / 'gitlab/tests/.state'
        state.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=state) as directory:
            repo = Path(directory)
            ssh = repo / 'ssh'
            ssh.write_text('''#!/usr/bin/env python3
import io, os, sys, tarfile
if '--artifacts' not in sys.argv:
    sys.exit(int(os.environ['EXECUTION_RC']))
if os.environ['EXPORT_RC'] != '0':
    sys.exit(int(os.environ['EXPORT_RC']))
with tarfile.open(fileobj=sys.stdout.buffer, mode='w|') as archive:
    info = tarfile.TarInfo('ctl-run.json')
    info.size = 2
    archive.addfile(info, io.BytesIO(b'{}'))
''')
            ssh.chmod(0o755)
            for execution, export, expected in ((7, 0, 7), (7, 22, 7), (0, 22, 2), (0, 0, 0)):
                with self.subTest(execution=execution, export=export):
                    result = subprocess.run(['bash', str(ROOT / 'mesh/labs/gitlab/project-seed/scripts/ctl-ci.sh'),
                                             '--pipeline', '10'], cwd=repo, capture_output=True,
                        env=dict(os.environ, PATH=str(repo) + os.pathsep + os.environ['PATH'],
                                 CTL_SSH_KEY='fixture', CTL_KNOWN_HOSTS='fixture',
                                 EXECUTION_RC=str(execution), EXPORT_RC=str(export)))
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertEqual((repo / 'mesh-artifacts/ctl-run.json').exists(), export == 0)


if __name__ == '__main__':
    unittest.main()
