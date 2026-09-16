"""Verify preflight with the Ansible runtime installed in the controller image."""

import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "preflight.sh"


@unittest.skipUnless(shutil.which("ansible-inventory"), "requires controller Ansible runtime")
class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = self.root / "ansible.cfg"
        self.inventory = self.root / "inventory with spaces.ini"
        self.inventory.write_text("[web]\nhost-a\nhost-b\n[other]\nhost-a\n")
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("ANSIBLE_", "CONTROLLER_"))
        }
        self.env.update({
            "ANSIBLE_CONFIG": str(self.config),
            "CONTROLLER_CONFIG_DIR": str(self.root),
            "CONTROLLER_LOG_DIR": str(self.root / "logs"),
            "CONTROLLER_HOME": str(self.root / "home"),
            "CONTROLLER_USER": pwd.getpwuid(os.getuid()).pw_name,
        })
        self.configure(str(self.inventory))

    def configure(self, inventory, ssh_args="-C"):
        self.config.write_text(
            f"[defaults]\ninventory = {inventory}\nhost_key_checking = True\n"
            f"[ssh_connection]\nssh_args = {ssh_args}\n"
        )

    def run_preflight(self, expected=0):
        result = subprocess.run(
            ["sh", str(SCRIPT), "--strict"], env=self.env,
            text=True, capture_output=True, timeout=30,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def test_static_hosts_without_variables_and_spaces_in_path(self):
        self.assertIn("2 host(s)", self.run_preflight())

    def test_multiple_inventory_sources(self):
        extra = self.root / "extra.ini"
        extra.write_text("host-c\n")
        self.configure(f"{self.inventory},{extra}")
        self.assertIn("3 host(s)", self.run_preflight())

    def test_missing_inventory_is_fatal(self):
        self.inventory.unlink()
        self.assertIn("does not parse completely", self.run_preflight(expected=1))

    def test_partially_missing_inventory_is_fatal(self):
        self.configure(f"{self.inventory},{self.root / 'missing.ini'}")
        self.assertIn("does not parse completely", self.run_preflight(expected=1))

    def test_invalid_configuration_is_fatal(self):
        self.config.write_text("[defaults\nbroken config")
        self.assertIn("cannot read Ansible configuration", self.run_preflight(expected=1))

    def test_ssh_plugin_configuration_is_checked(self):
        self.configure(str(self.inventory), "-o StrictHostKeyChecking=no")
        self.assertIn("disable StrictHostKeyChecking", self.run_preflight(expected=1))

    def test_old_image_config_fallback(self):
        del self.env["ANSIBLE_CONFIG"]
        self.assertIn(f"using {self.config}", self.run_preflight())


if __name__ == "__main__":
    unittest.main()
