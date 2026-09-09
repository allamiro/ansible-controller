"""Check the seed deployment command against a real local Runner-style checkout."""
import json
import os
from pathlib import Path
import subprocess
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
            (repo / 'ssh').write_text('#!/usr/bin/env python3\nimport json,os,sys\nopen(os.environ["SSH_ARGS"], "w").write(json.dumps(sys.argv[1:]))\n')
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


if __name__ == '__main__':
    unittest.main()
