"""Local regressions using real Git checkouts and a harmless Ansible stand-in."""
import json
import fcntl
import io
import os
from pathlib import Path
import subprocess
import tempfile
import tarfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ControllerTests(unittest.TestCase):
    def setUp(self):
        state = ROOT / "gitlab/tests/.state"
        state.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=state)
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.repo = self.base / "repos/group/project.git"
        self.repo.mkdir(parents=True)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        (self.repo / "playbooks/vars").mkdir(parents=True)
        (self.repo / "playbooks/site.yml").write_text("[]\n")
        (self.repo / "inventory.ini").write_text("localhost\n")
        self.secrets = self.base / "secrets"
        self.secrets.mkdir()
        (self.secrets / "test.token").write_text("test:unused\n")
        self.map = self.base / "environments.json"
        self.map.write_text(json.dumps({"environments": {"test": {
            "mode": "standalone", "gitlab_url": (self.base / "repos").as_uri(),
            "allowed_projects": ["group/project"], "inventory": "inventory.ini"}}}))
        self.bin = self.base / "bin"
        self.bin.mkdir()
        fake = self.bin / "ansible-playbook"
        fake.write_text('#!/bin/sh\nprintf "%s" "$PWD" > "$TEST_MARKER"\nprintf "%s" "${ANSIBLE_CONFIG:-}" > "$TEST_CONFIG_MARKER"\nprintf "%s" "${ANSIBLE_VAULT_PASSWORD_FILE:-}" > "$TEST_VAULT_MARKER"\nexit "${TEST_RC:-0}"\n')
        fake.chmod(0o755)
        self.env = dict(os.environ, CTL_RUN_ENVS=str(self.map),
                        CTL_RUN_SECRETS=str(self.secrets), CTL_RUN_DIR=str(self.base / "runs"),
                        TEST_MARKER=str(self.base / "executed"),
                        TEST_CONFIG_MARKER=str(self.base / "config-path"),
                        TEST_VAULT_MARKER=str(self.base / "vault-path"),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"])

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True).strip()

    def run_ctl(self, *extra, commit=True):
        if commit:
            self.git("add", "-A")
            self.git("commit", "-qm", "fixture", "--allow-empty")
        return subprocess.run(["bash", str(ROOT / "gitlab/bin/ctl-run"),
                               "--env", "test", "--project", "group/project",
                               "--sha", self.git("rev-parse", "HEAD"),
                               "--playbook", "playbooks/site.yml", *extra],
                              env=self.env, text=True, capture_output=True)

    def test_external_symlink_cannot_overwrite_controller_file(self):
        victim = self.base / "controller-secret"
        victim.write_text("unchanged")
        (self.repo / "playbooks/vars/commit.yml").symlink_to(victim)
        result = self.run_ctl()
        self.assertEqual(victim.read_text(), "unchanged")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / "executed").exists())

    def test_private_staging_under_permissive_caller_umask(self):
        previous = os.umask(0o022)
        try:
            result = self.run_ctl()
        finally:
            os.umask(previous)
        self.assertEqual(result.returncode, 0, result.stderr)
        for record in (self.base / "runs/records").glob("*.json"):
            stage = Path(json.loads(record.read_text())["stage_dir"])
            self.assertEqual(stage.stat().st_mode & 0o077, 0)

    def test_project_root_is_execution_cwd(self):
        result = self.run_ctl()
        self.assertEqual(result.returncode, 0, result.stderr)
        records = list((self.base / "runs/records").glob("*.json"))
        self.assertEqual((self.base / "executed").read_text(),
                         json.loads(records[0].read_text())["stage_dir"])

    @unittest.skipUnless(os.environ.get('CTL_RUN_TEST_MESH_STUB') == '1', 'requires isolated mesh transport stand-in')
    def test_mesh_output_streams_to_private_log_and_preserves_exit_code(self):
        config = json.loads(self.map.read_text())
        config['environments']['test'].update(mode='mesh', node='fixture-node')
        self.map.write_text(json.dumps(config))
        result = self.run_ctl()
        self.assertEqual(result.returncode, 7)
        logs = list((self.base / 'runs/logs').glob('*.log'))
        self.assertEqual(len(logs), 1)
        self.assertGreater(logs[0].stat().st_size, 1024 * 1024)
        self.assertEqual(logs[0].stat().st_mode & 0o077, 0)
        record = json.loads(next((self.base / 'runs/records').glob('*.json')).read_text())
        self.assertEqual(record['mesh_job'], '00000000-0000-0000-0000-000000000001')
        self.assertEqual(record['rc'], '7')

    def test_real_failure_rc_preserved(self):
        self.env["TEST_RC"] = "7"
        self.assertEqual(self.run_ctl().returncode, 7)

    def test_pipeline_retry_replays_success_without_execution(self):
        first = self.run_ctl('--pipeline', '10', '--job', '20')
        self.assertEqual(first.returncode, 0, first.stderr)
        marker = self.base / 'executed'
        original = marker.read_text()
        marker.unlink()
        retry = self.run_ctl('--pipeline', '10', '--job', '21', commit=False)
        self.assertEqual(retry.returncode, 0, retry.stderr)
        self.assertIn('no new execution', retry.stdout)
        self.assertFalse(marker.exists())
        fresh = self.run_ctl('--pipeline', '11', '--job', '22', commit=False)
        self.assertEqual(fresh.returncode, 0, fresh.stderr)
        self.assertNotEqual(marker.read_text(), original)

    def test_artifact_export_does_not_contend_with_another_dispatch(self):
        self.assertEqual(self.run_ctl('--pipeline', '10').returncode, 0)
        with (self.base / 'runs/locks/test').open('w') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = subprocess.run(['bash', str(ROOT / 'gitlab/bin/ctl-run'),
                '--artifacts', '--env', 'test', '--project', 'group/project',
                '--sha', self.git('rev-parse', 'HEAD'), '--playbook', 'playbooks/site.yml',
                '--pipeline', '10'], env=self.env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        with tarfile.open(fileobj=io.BytesIO(result.stdout)) as archive:
            record = json.load(archive.extractfile('ctl-run.json'))
            self.assertEqual(record['gitlab_pipeline'], '10')

    def test_pipeline_retry_preserves_failure(self):
        self.env['TEST_RC'] = '7'
        self.assertEqual(self.run_ctl('--pipeline', '10').returncode, 7)
        (self.base / 'executed').unlink()
        self.env['TEST_RC'] = '0'
        self.assertEqual(self.run_ctl('--pipeline', '10', commit=False).returncode, 7)
        self.assertFalse((self.base / 'executed').exists())

    def test_pipeline_identity_cannot_change_commit(self):
        self.assertEqual(self.run_ctl('--pipeline', '10').returncode, 0)
        (self.base / 'executed').unlink()
        retry = self.run_ctl('--pipeline', '10')
        self.assertNotEqual(retry.returncode, 0)
        self.assertIn('different commit', retry.stderr)
        self.assertFalse((self.base / 'executed').exists())

    def _mesh_env(self, jobs_dir):
        self.map.write_text(json.dumps({"environments": {"test": {
            "mode": "mesh", "gitlab_url": (self.base / "repos").as_uri(),
            "allowed_projects": ["group/project"], "inventory": "inventory.ini",
            "node": "exec-a"}}}))
        return dict(self.env, CTL_RUN_MESH_JOBS=str(jobs_dir))

    def _dispatch(self, env):
        self.git("add", "-A"); self.git("commit", "-qm", "fixture", "--allow-empty")
        return subprocess.run(["bash", str(ROOT / "gitlab/bin/ctl-run"),
                               "--env", "test", "--project", "group/project",
                               "--sha", self.git("rev-parse", "HEAD"),
                               "--playbook", "playbooks/site.yml"],
                              env=env, text=True, capture_output=True)

    def test_mesh_guard_refuses_every_unestablished_record(self):
        """A record is resolved only when it says so. Anything the guard cannot
        read or cannot understand means the outcome is not established, which is
        precisely what it exists to refuse on."""
        jobs = self.base / "state/jobs"
        cases = {
            "truncated": '{"node":"exec-a"',                 # no status at all
            "empty": "",                                      # zero-length record
            "future": '{"status":"quarantined"}',             # status this build predates
            "ambiguous": '{"status":"submit-ambiguous"}',     # the classic case
            "truncated_success": '{"status":"succeeded"',
            "truncated_refusal": '{"status":"submit-failed-pre"',
        }
        for name, body in cases.items():
            (jobs / name).mkdir(parents=True)
            (jobs / name / "meta.json").write_text(body)
        (jobs / "norecord").mkdir()                           # job directory, no meta.json
        out = self._dispatch(self._mesh_env(jobs))
        self.assertNotEqual(out.returncode, 0)
        for name in list(cases) + ["norecord"]:
            self.assertIn(name, out.stderr, f"{name} was silently treated as finished")
        self.assertFalse((self.base / "executed").exists())

    def test_mesh_guard_bootstraps_a_fresh_state_volume(self):
        """A fresh mesh-state volume has no jobs/ child — mesh-run creates it on
        first dispatch — so requiring it would refuse the very first deployment."""
        state = self.base / "state"
        state.mkdir()
        out = self._dispatch(self._mesh_env(state / "jobs"))
        self.assertNotIn("retry guard cannot prove", out.stderr)
        self.assertNotIn("unresolved mesh job", out.stderr)
        self.assertTrue((state / "jobs").is_dir(), "the guard did not initialise the jobs directory")

    def test_mesh_guard_rejects_a_partial_failed_status(self):
        """failed rc=<n> is terminal; failed rc=<n> followed by anything else is a
        record nobody has established the meaning of."""
        jobs = self.base / "state/jobs"
        (jobs / "partial").mkdir(parents=True)
        (jobs / "partial" / "meta.json").write_text('{"status":"failed rc=2 pending"}')
        out = self._dispatch(self._mesh_env(jobs))
        self.assertNotEqual(out.returncode, 0)
        self.assertIn("partial", out.stderr)
        self.assertFalse((self.base / "executed").exists())

    def test_mesh_guard_allows_dispatch_once_every_record_is_terminal(self):
        """The mirror of the above: succeeded and failed rc=<n> are terminal, so
        the guard must let those through — otherwise it would block forever."""
        jobs = self.base / "state/jobs"
        (jobs / "ok").mkdir(parents=True)
        (jobs / "ok" / "meta.json").write_text('{"status":"succeeded"}')
        (jobs / "bad").mkdir()
        (jobs / "bad" / "meta.json").write_text('{"status":"failed rc=2"}')
        (jobs / "refused").mkdir()
        (jobs / "refused" / "meta.json").write_text('{"status":"submit-failed-pre"}')
        out = self._dispatch(self._mesh_env(jobs))
        self.assertNotIn("unresolved mesh job", out.stderr)

    def test_collect_passes_relocated_jobs_directory(self):
        # Copy only the wrapper and replace its fixed executable path with a
        # harmless recorder; never write to the installed mesh dispatcher.
        fake = self.bin / "mesh-run"
        fake.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        fake.chmod(0o755)
        wrapper = self.base / "ctl-run"
        wrapper.write_text((ROOT / "gitlab/bin/ctl-run").read_text().replace(
            'MESH_RUN=/usr/local/mesh/bin/mesh-run', f'MESH_RUN="{fake}"',
        ))
        uuid = '00000000-0000-0000-0000-000000000001'
        jobs = self.base / "relocated/jobs"
        result = subprocess.run(
            ['bash', str(wrapper), '--collect', uuid],
            env=dict(self.env, CTL_RUN_MESH_JOBS=str(jobs)),
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['--collect', uuid, '--jobs-dir', str(jobs)])

    def test_mesh_guard_fails_closed_when_job_records_are_unreadable(self):
        """With the state volume unmounted or relocated the guard can see nothing,
        which is not the same as having nothing to see."""
        out = self._dispatch(self._mesh_env(self.base / "absent-state/jobs"))
        self.assertNotEqual(out.returncode, 0, "dispatch proceeded with unreadable job records")
        self.assertIn("retry guard cannot prove", out.stderr)
        self.assertFalse((self.base / "executed").exists(), "a playbook ran despite the blind guard")

    @unittest.skipIf(os.getuid() == 0, "root bypasses directory permission bits")
    def test_unwritable_jobs_directory_refuses_before_pipeline_claim(self):
        jobs = self.base / "state/jobs"
        jobs.mkdir(parents=True)
        jobs.chmod(0o555)
        self.addCleanup(jobs.chmod, 0o700)
        self.env = self._mesh_env(jobs)
        result = self.run_ctl('--pipeline', '10')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unwritable', result.stderr)
        self.assertEqual(list((self.base / 'runs/requests').glob('*.json')), [])

    def test_unresolved_request_refuses_second_execution(self):
        self.assertEqual(self.run_ctl('--pipeline', '10').returncode, 0)
        record = next((self.base / 'runs/records').glob('*.json'))
        data = json.loads(record.read_text())
        data.update(status='started', rc='')
        record.write_text(json.dumps(data))
        (self.base / 'executed').unlink()
        retry = self.run_ctl('--pipeline', '10', commit=False)
        self.assertEqual(retry.returncode, 2)
        self.assertIn('outcome unresolved', retry.stderr)
        self.assertFalse((self.base / 'executed').exists())

    @unittest.skipUnless(Path('/configs/ansible.cfg').is_file(), 'requires mounted site config')
    def test_site_config_restored_when_environment_is_sanitized(self):
        self.env.pop('ANSIBLE_CONFIG', None)
        result = self.run_ctl()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / 'config-path').read_text(), '/configs/ansible.cfg')

    @unittest.skipUnless(Path('/home/ansible/.vault_pass').is_file(), 'requires mounted Vault file')
    def test_vault_file_restored_when_environment_is_sanitized(self):
        self.env.pop('ANSIBLE_VAULT_PASSWORD_FILE', None)
        result = self.run_ctl()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / 'vault-path').read_text(), '/home/ansible/.vault_pass')

    def test_explicit_administrator_config_is_preserved(self):
        config = self.base / 'admin.cfg'
        config.write_text('[defaults]\n')
        self.env['ANSIBLE_CONFIG'] = str(config)
        result = self.run_ctl()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / 'config-path').read_text(), str(config))

    def test_nested_lfs_is_rejected(self):
        (self.repo / "playbooks/.gitattributes").write_text("*.dat filter=lfs diff=lfs\n")
        result = self.run_ctl()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / "executed").exists())

    def test_reject_malformed_job_id_before_fetch(self):
        result = self.run_ctl("--job", "*")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.base / "executed").exists())


if __name__ == "__main__":
    unittest.main()
