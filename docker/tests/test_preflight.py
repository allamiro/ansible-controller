"""Exercise preflight without a running controller or managed hosts."""

import json
import os
import pwd
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "preflight.sh"


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.config = self.root / "ansible.cfg"
        self.config.touch()
        self.dump = self.root / "config.txt"
        self.dump.write_text(
            f"CONFIG_FILE() = {self.config}\n"
            "HOST_KEY_CHECKING(default) = True\n"
            "DEFAULT_PRIVATE_KEY_FILE(default) = None\n"
            "DEFAULT_VAULT_PASSWORD_FILE(default) = None\n"
            "DEFAULT_HOST_LIST(default) = ['inventory with spaces.ini']\n"
        )
        self.ssh = self.root / "ssh.txt"
        self.ssh.write_text("ssh_args(default) = -C\n")
        self.inventory = self.root / "inventory.json"
        self.inventory.write_text(json.dumps({
            "_meta": {"hostvars": {}},
            "web": {"hosts": ["host-a", "host-b"]},
            "all": {"children": ["web"]},
        }))
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "ANSIBLE_CONFIG": str(self.config),
            "ANSIBLE_VAULT_PASSWORD_FILE": "",
            "CONTROLLER_USER": pwd.getpwuid(os.getuid()).pw_name,
            "CONTROLLER_CONFIG_DIR": str(self.root),
            "CONTROLLER_LOG_DIR": str(self.root / "logs"),
            "CONTROLLER_HOME": str(self.root / "home"),
            "TEST_ROOT": str(self.root),
            "CONFIG_RC": "0", "INVENTORY_RC": "0", "SSH_RC": "0",
        }
        self.stub("ansible-config", '''
if [ "$*" = "dump -t connection ssh" ]; then
    cat "$TEST_ROOT/ssh.txt"
    exit "$SSH_RC"
fi
cat "$TEST_ROOT/config.txt"
exit "$CONFIG_RC"
''')
        self.stub("ansible-inventory", '''
[ "$ANSIBLE_INVENTORY_ANY_UNPARSED_IS_FAILED" = True ] || exit 99
cat "$TEST_ROOT/inventory.json"
exit "$INVENTORY_RC"
''')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)

    def run_preflight(self, *args, expected=0):
        result = subprocess.run(
            ["sh", str(SCRIPT), *args], env=self.env,
            text=True, capture_output=True, timeout=15,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_counts_hosts_without_hostvars_and_deduplicates_groups(self):
        self.inventory.write_text(json.dumps({
            "_meta": {"hostvars": {"host-a": {}}},
            "web": {"hosts": ["host-a", "host-b"]},
            "other": {"hosts": ["host-b"]},
        }))
        self.assertIn("2 host(s)", self.run_preflight("--strict"))

    def test_config_failure_cannot_be_hidden_by_filter(self):
        self.env["CONFIG_RC"] = "5"
        self.assertIn("cannot read Ansible configuration", self.run_preflight(expected=1))

    def test_inventory_failure_with_valid_json_is_fatal(self):
        self.env["INVENTORY_RC"] = "4"
        self.assertIn("does not parse completely", self.run_preflight(expected=1))

    def test_malformed_inventory_json_is_fatal(self):
        self.inventory.write_text("not json")
        self.run_preflight(expected=1)

    def test_empty_inventory_is_a_risk(self):
        self.inventory.write_text('{"_meta": {"hostvars": {}}}')
        self.assertIn("0 hosts", self.run_preflight())
        self.run_preflight("--strict", expected=1)

    def test_ssh_plugin_options_are_checked(self):
        for name in ("ssh_args", "ssh_common_args", "ssh_extra_args"):
            for option in ("StrictHostKeyChecking=no", "StrictHostKeyChecking off"):
                with self.subTest(name=name, option=option):
                    self.ssh.write_text(f"{name}(test) = -o {option}\n")
                    self.assertIn("SSH options", self.run_preflight("--strict", expected=1))

    def test_ssh_config_failure_is_fatal(self):
        self.env["SSH_RC"] = "1"
        self.run_preflight(expected=1)

    def test_inventory_secrets_are_not_reported(self):
        self.inventory.write_text(json.dumps({
            "_meta": {"hostvars": {"host-a": {"ansible_password": "secret-value"}}},
        }))
        self.assertNotIn("secret-value", self.run_preflight())

    def test_failed_dependency_install_is_fatal(self):
        (self.root / "requirements.yml").touch()
        logs = self.root / "logs"
        logs.mkdir()
        (logs / "galaxy-install.status").write_text("rc=1 finished=test\n")
        self.assertIn("install rc=1", self.run_preflight(expected=1))

    def test_unknown_argument_is_rejected(self):
        self.assertIn("usage:", self.run_preflight("--strcit", expected=2))

    def test_configured_vault_file_permissions_are_checked(self):
        vault = self.root / "custom-vault"
        vault.write_text("secret-vault-value")
        self.dump.write_text(self.dump.read_text().replace(
            "DEFAULT_VAULT_PASSWORD_FILE(default) = None",
            f"DEFAULT_VAULT_PASSWORD_FILE(test) = {vault}",
        ))
        vault.chmod(0o644)
        output = self.run_preflight("--strict", expected=1)
        self.assertIn(str(vault), output)
        self.assertNotIn("secret-vault-value", output)
        vault.chmod(0o600)
        self.run_preflight("--strict")
        vault.unlink()
        self.assertIn("configured Vault password file does not exist", self.run_preflight(expected=1))

    @unittest.skipUnless(os.getuid() == 0, "requires root to switch controller account")
    def test_root_owned_key_is_not_usable_by_controller_account(self):
        key = self.root / "private-key"
        key.write_text("private-key-material")
        key.chmod(0o600)
        self.env["CONTROLLER_USER"] = "nobody"
        self.dump.write_text(self.dump.read_text().replace(
            "DEFAULT_PRIVATE_KEY_FILE(default) = None",
            f"DEFAULT_PRIVATE_KEY_FILE(test) = {key}",
        ))
        self.assertIn("not readable by nobody", self.run_preflight(expected=1))


if __name__ == "__main__":
    unittest.main()
