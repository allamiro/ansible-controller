"""Local regressions using real Git checkouts and a harmless Ansible stand-in."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
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
        fake.write_text('#!/bin/sh\nprintf "%s" "$PWD" > "$TEST_MARKER"\nprintf "%s" "${ANSIBLE_CONFIG:-}" > "$TEST_CONFIG_MARKER"\nexit "${TEST_RC:-0}"\n')
        fake.chmod(0o755)
        self.env = dict(os.environ, CTL_RUN_ENVS=str(self.map),
                        CTL_RUN_SECRETS=str(self.secrets), CTL_RUN_DIR=str(self.base / "runs"),
                        TEST_MARKER=str(self.base / "executed"),
                        TEST_CONFIG_MARKER=str(self.base / "config-path"),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"])

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True).strip()

    def run_ctl(self, *extra):
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

    def test_real_failure_rc_preserved(self):
        self.env["TEST_RC"] = "7"
        self.assertEqual(self.run_ctl().returncode, 7)

    @unittest.skipUnless(Path('/configs/ansible.cfg').is_file(), 'requires mounted site config')
    def test_site_config_restored_when_environment_is_sanitized(self):
        self.env.pop('ANSIBLE_CONFIG', None)
        result = self.run_ctl()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.base / 'config-path').read_text(), '/configs/ansible.cfg')

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
