"""A voluntary notice must never block or contaminate automation streams."""

import errno
import os
from pathlib import Path
import pty
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
NOTICE = ROOT / 'support-notice.sh'
HOOK = ROOT / 'support-shell.bash'
CI_KEYS = ('CI', 'GITHUB_ACTIONS', 'GITLAB_CI', 'TF_BUILD', 'JENKINS_URL',
           'BUILDKITE', 'CIRCLECI', 'TEAMCITY_VERSION')


def drain(fd):
    chunks = []
    while True:
        try:
            data = os.read(fd, 65536)
            if not data:
                break
            chunks.append(data)
        except OSError as error:
            if error.errno == errno.EIO:
                break
            raise
    return b''.join(chunks).decode()


class SupportNoticeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.env = {key: value for key, value in os.environ.items()
                    if key not in CI_KEYS and not key.startswith('ANSIBLE_CONTROLLER_SUPPORT_')}
        self.env.update(HOME=str(self.home), TERM='xterm')

    def terminal(self, command=None, env=None, piped=None, input_data=None):
        out_master, out_slave = pty.openpty()
        err_master, err_slave = pty.openpty()
        streams = dict(stdin=out_slave, stdout=out_slave, stderr=err_slave)
        if piped:
            streams[piped] = subprocess.PIPE
        process = None
        try:
            process = subprocess.Popen(command or ['sh', str(NOTICE)],
                                       env=env or self.env, **streams)
            if input_data:
                os.write(out_master, input_data)
            out, err = process.communicate(timeout=5)
        finally:
            if process is not None and process.poll() is None:
                process.kill()
                process.wait()
            os.close(out_slave)
            os.close(err_slave)
            terminal_out = drain(out_master)
            terminal_err = drain(err_master)
            os.close(out_master)
            os.close(err_master)
        return process.returncode, terminal_out + (out or b'').decode(), terminal_err + (err or b'').decode()

    def test_terminal_notice_needs_no_input_and_uses_only_stderr(self):
        rc, out, err = self.terminal()
        self.assertEqual(rc, 0)
        self.assertEqual(out, '')
        for label in ('Learn more:', 'Sponsor:', 'Continue free:', 'No host limit'):
            self.assertIn(label, err)
        self.assertIn('https://github.com/sponsors/allamiro', err)
        self.assertIn('https://buymeacoffee.com/pcileky2q', err)

    def test_any_redirected_stream_suppresses_notice(self):
        for stream in ('stdin', 'stdout', 'stderr'):
            with self.subTest(stream=stream):
                self.assertEqual(self.terminal(piped=stream), (0, '', ''))

    def test_ci_is_silent_even_with_terminal(self):
        for key in CI_KEYS:
            with self.subTest(key=key):
                self.assertEqual(self.terminal(env=dict(self.env, **{key: '1'})), (0, '', ''))

    def test_environment_opt_out(self):
        self.assertEqual(self.terminal(env=dict(self.env, ANSIBLE_CONTROLLER_SUPPORT_NOTICE='0')), (0, '', ''))

    def test_account_opt_out(self):
        (self.home / '.hushlogin').touch()
        self.assertEqual(self.terminal(), (0, '', ''))

    def hook_copy(self):
        path = self.home / 'support-hook.bash'
        # Exercise the actual hook with the checkout's helper; no installation
        # or mutation of the test host's shell configuration is needed.
        path.write_text(HOOK.read_text().replace(
            '/usr/local/bin/controller-support', f'sh "{NOTICE}"'))
        return path

    def test_noninteractive_and_command_shells_keep_output_and_exit_status(self):
        hook = self.hook_copy()
        for flag in ('-c', '-ic'):
            with self.subTest(flag=flag):
                rc, out, err = self.terminal([
                    'bash', '--noprofile', '--norc', flag,
                    '. "$1"; printf protocol-marker; exit 7', 'fixture', str(hook),
                ])
                self.assertEqual(rc, 7)
                self.assertEqual(out, 'protocol-marker')
                self.assertNotIn('optional support', err)

    def test_interactive_shell_shows_once_and_keeps_exit_status(self):
        hook = self.hook_copy()
        rc, _, err = self.terminal(
            ['bash', '--noprofile', '--rcfile', str(hook), '-i'],
            input_data=f'. "{hook}"\nexit 7\n'.encode(),
        )
        self.assertEqual(rc, 7)
        self.assertEqual(err.count('Ansible Controller mesh — optional support'), 1)

    @unittest.skipUnless(os.environ.get('SUPPORT_NOTICE_IMAGE'), 'image integration check')
    def test_installed_image_shell_scope(self):
        mesh = os.environ['SUPPORT_NOTICE_IMAGE'] == 'mesh'
        self.assertEqual(Path('/usr/local/bin/controller-support').exists(), mesh)
        rc, _, err = self.terminal(
            ['bash', '--noprofile', '-i'], input_data=b'exit 7\n',
        )
        self.assertEqual(rc, 7)
        self.assertEqual(err.count('Ansible Controller mesh — optional support'), int(mesh))

        for flag in ('-c', '-ic'):
            with self.subTest(flag=flag):
                rc, out, err = self.terminal([
                    'bash', '--noprofile', flag, 'printf protocol-marker; exit 7',
                ])
                self.assertEqual((rc, out), (7, 'protocol-marker'))
                self.assertNotIn('optional support', err)


if __name__ == '__main__':
    unittest.main()
