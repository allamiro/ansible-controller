"""Run the overview selection step against local commits and a fake Actions API."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]


class OverviewTests(unittest.TestCase):
    def test_queued_job_publishes_newest_successful_content_and_fails_closed(self):
        workflow = yaml.safe_load((ROOT / '.github/workflows/docker-publish.yml').read_text())
        step = next(s for s in workflow['jobs']['hub-overviews']['steps']
                    if s.get('id') == 'overview-revision')['run']
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            origin = root / 'origin'
            origin.mkdir()

            def git(*args, cwd=origin):
                return subprocess.check_output(['git', *args], cwd=cwd, stderr=subprocess.DEVNULL, text=True).strip()

            git('init', '-q')
            git('config', 'user.name', 'Fixture')
            git('config', 'user.email', 'fixture@example.invalid')
            descriptions = origin / '.github/dockerhub'
            descriptions.mkdir(parents=True)
            revisions = []
            for version in ('old', 'published', 'unpublished'):
                (descriptions / 'descriptions.json').write_text(json.dumps({'ansible-controller': version}))
                (descriptions / 'ansible-controller.md').write_text(version)
                git('add', '.')
                git('commit', '-qm', version)
                revisions.append(git('rev-parse', 'HEAD'))
            checkout = root / 'checkout'
            git('clone', '-q', str(origin), str(checkout))
            stub = '''gh() {
  if [ "$API_FAILURE" = 1 ]; then return 1; fi
  case "$*" in
    *workflows/docker-publish.yml/runs*) printf '%s\\n' "$RUNS";;
    *runs/3/jobs*) :;;
    *runs/2/jobs*) if [ "$SECOND_PUBLISHED" = 1 ]; then echo 22; fi;;
    *runs/1/jobs*) echo 11;;
    *) return 2;;
  esac
}
'''
            for second, failure, selected in [('1', '0', 'published'), ('0', '0', 'old'), ('1', '1', None)]:
                with self.subTest(second=second, failure=failure):
                    git('checkout', '--detach', revisions[0], cwd=checkout)
                    output = root / 'outputs'
                    output.write_text('')
                    result = subprocess.run(['bash', '-euo', 'pipefail', '-c', stub + step], cwd=checkout,
                        env=dict(os.environ, API_FAILURE=failure, SECOND_PUBLISHED=second,
                                 RUNS='\n'.join(f'{n}\t{n}\t{rev}' for n, rev in enumerate(revisions, 1)),
                                 GITHUB_REPOSITORY='fixture/repository', GITHUB_OUTPUT=str(output),
                                 OVERVIEW_IMAGE='ansible-controller'), capture_output=True, text=True)
                    if selected is None:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(output.read_text(), '')
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(output.read_text().strip(), 'short=' + selected)
                        self.assertEqual((checkout / '.github/dockerhub/ansible-controller.md').read_text(), selected)


if __name__ == '__main__':
    unittest.main()
