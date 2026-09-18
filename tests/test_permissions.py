"""Permission selection without invoking real sudo, PolicyKit, or Tk windows."""
import subprocess
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from installer_gui import administrative_prefix


class PermissionTests(unittest.TestCase):
    def setUp(self):
        patcher = patch('installer_gui.os.geteuid', return_value=1000)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_existing_sudo_authorization_avoids_policykit_dialog(self):
        with patch('installer_gui.shutil.which', side_effect=lambda name: '/usr/bin/' + name), \
                patch('installer_gui.subprocess.run', return_value=SimpleNamespace(returncode=0)) as run:
            self.assertEqual(administrative_prefix(), ['sudo', '-n', '--'])
        self.assertEqual(run.call_args.args[0], ['sudo', '-n', '--', 'true'])
        self.assertEqual(run.call_args.kwargs['stdin'], subprocess.DEVNULL)

    def test_password_required_falls_back_to_policykit(self):
        with patch('installer_gui.shutil.which', side_effect=lambda name: '/usr/bin/' + name), \
                patch('installer_gui.subprocess.run', return_value=SimpleNamespace(returncode=1)):
            self.assertEqual(administrative_prefix(), ['pkexec'])

    def test_passwordless_sudo_works_without_pkexec(self):
        with patch('installer_gui.shutil.which', side_effect=lambda name: '/usr/bin/sudo' if name == 'sudo' else None), \
                patch('installer_gui.subprocess.run', return_value=SimpleNamespace(returncode=0)):
            self.assertEqual(administrative_prefix(), ['sudo', '-n', '--'])

    def test_no_authorization_does_not_run_unprivileged_or_prompt_on_stdin(self):
        with patch('installer_gui.shutil.which', side_effect=lambda name: '/usr/bin/sudo' if name == 'sudo' else None), \
                patch('installer_gui.subprocess.run', return_value=SimpleNamespace(returncode=1)):
            with self.assertRaisesRegex(RuntimeError, 'permisos'):
                administrative_prefix()

    def test_timeout_falls_back_to_policykit(self):
        with patch('installer_gui.shutil.which', side_effect=lambda name: '/usr/bin/' + name), \
                patch('installer_gui.subprocess.run', side_effect=subprocess.TimeoutExpired('sudo', 3)):
            self.assertEqual(administrative_prefix(), ['pkexec'])

    def test_root_does_not_request_further_authorization(self):
        with patch('installer_gui.os.geteuid', return_value=0), \
                patch('installer_gui.subprocess.run') as run:
            self.assertEqual(administrative_prefix(), [])
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
