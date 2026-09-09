"""Isolated regression checks; never invoke the deployment entrypoints."""
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.home = self.root / 'user'
        self.home.mkdir()

    def shell(self, code, **variables):
        env = dict(os.environ, INSTALL_HOME=str(self.home), **variables)
        return subprocess.run(
            ['bash', '-c', 'set -eu; source scripts/common.sh; ' + code],
            cwd=ROOT, env=env, text=True, capture_output=True,
        )

    def test_rejects_system_home_relative_and_traversal_paths(self):
        for path in ['', '/', '/etc', '/usr/local', '/var/lib', '/opt',
                     str(self.home), str(self.home) + '/',
                     str(self.home / '..'), str(self.home / '../..'), 'gateway']:
            with self.subTest(path=path):
                result = self.shell('validate_app_dir', APP_DIR=path)
                self.assertNotEqual(result.returncode, 0)

    def test_rejects_symlink_escape_and_accepts_app_directory(self):
        (self.home / 'escape').symlink_to('/etc')
        result = self.shell('validate_app_dir', APP_DIR=str(self.home / 'escape'))
        self.assertNotEqual(result.returncode, 0)
        result = self.shell('validate_app_dir; printf "%s" "$APP_DIR"',
                            APP_DIR=str(self.home / 'gateway/../gateway'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(self.home / 'gateway'))

    def test_uninstall_requires_matching_registration_and_application(self):
        app = self.home / 'gateway'
        app.mkdir()
        code = '''as_root() { printf '%s' "$REGISTERED"; }
require_registered_installation'''
        for registered in ['', str(self.home / 'unrelated'), str(app)]:
            result = self.shell(code, APP_DIR=str(app), REGISTERED=registered)
            self.assertNotEqual(result.returncode, 0)
        (app / '.git').mkdir()
        (app / 'main.py').touch()
        result = self.shell(code, APP_DIR=str(app), REGISTERED=str(app))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_failed_update_never_restarts_mutated_runtime(self):
        for mutated in ['true', 'false']:
            result = self.shell('''as_root() { printf 'SERVICE_START\n'; }
service_is_installed() { return 1; }
SERVICE_WAS_ACTIVE=true
trap finish_service_operation EXIT
exit 37''', RUNTIME_MUTATED=mutated)
            self.assertEqual(result.returncode, 37)
            self.assertEqual('SERVICE_START' in result.stdout, mutated == 'false')

    @unittest.skipUnless(shutil.which('flock'), 'flock requires util-linux')
    def test_second_installer_is_rejected_and_lock_is_released(self):
        lock = self.root / 'operation.lock'
        first = subprocess.Popen(
            ['bash', '-c', 'source scripts/common.sh; lock_installer_file "$1"; echo ready; read -r done',
             'bash', str(lock)], cwd=ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        )
        try:
            self.assertEqual(first.stdout.readline().strip(), 'ready')
            result = self.shell('lock_installer_file "$LOCK"', LOCK=str(lock))
            self.assertNotEqual(result.returncode, 0)
        finally:
            first.communicate('done\n', timeout=5)
        result = self.shell('lock_installer_file "$LOCK"', LOCK=str(lock))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_generated_start_script_preserves_shell_metacharacters(self):
        app = self.home / 'gateway $literal `literal`'
        app.mkdir()
        result = self.shell('''as_root() {
  case "$1" in chown|chmod) return 0 ;; *) "$@" ;; esac
}
run_as_install_user() { "$@"; }
create_start_script''', APP_DIR=str(app), INSTALL_USER='user', INSTALL_GROUP='staff')
        self.assertEqual(result.returncode, 0, result.stderr)
        script = app / 'start.sh'
        self.assertEqual(subprocess.run(['bash', '-n', str(script)]).returncode, 0)
        # Read back the generated cd argument without running Python or hardware workers.
        line = script.read_text().splitlines()[2]
        check = subprocess.run(['bash', '-c', line + '; pwd'], capture_output=True, text=True)
        self.assertEqual(check.stdout.strip(), str(app))

    def test_package_contains_no_secrets_and_requires_supported_python(self):
        result = subprocess.run(['bash', 'build-deb.sh', '--output-dir', str(self.root)],
                                cwd=ROOT, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        data = next(self.root.glob('*.deb')).read_bytes()
        self.assertEqual(data[:8], b'!<arch>\n')
        members, offset = {}, 8
        while offset < len(data):
            header = data[offset:offset + 60]
            length = int(header[48:58])
            name = header[:16].decode().strip().rstrip('/')
            offset += 60
            members[name] = data[offset:offset + length]
            offset += length + length % 2
        with tarfile.open(fileobj=io.BytesIO(members['data.tar.gz'])) as archive:
            names = archive.getnames()
            self.assertFalse(any(Path(name).name == '.env' for name in names))
            self.assertFalse(any(Path(name).name == 'gateway.json' for name in names))
            self.assertTrue(any(name.endswith('/.env.example') for name in names))
        with tarfile.open(fileobj=io.BytesIO(members['control.tar.gz'])) as archive:
            self.assertIn('python3 (>= 3.10)', archive.extractfile('control').read().decode())

    def test_service_migration_uses_custom_state_path_without_starting(self):
        destination = self.root / 'service'
        result = self.shell('''command() { return 0; }
getent() { return 1; }
as_root() {
  if [ "$1" = install ]; then cp "$4" "$SERVICE_OUTPUT";
  elif [ "$1" = systemctl ]; then printf 'systemctl %s\n' "$2"; fi
}
configure_systemd_service false''',
            APP_DIR=str(self.home / 'gateway'), INSTALL_USER='user',
            GATEWAY_STATE_DIR=str(self.root / 'custom state'), SERVICE_OUTPUT=str(destination))
        self.assertEqual(result.returncode, 0, result.stderr)
        content = destination.read_text()
        self.assertIn('--mode headless', content)
        self.assertIn('GATEWAY_CONFIG_PATH=' + str(self.root / 'custom state/gateway.json'), content)
        self.assertNotIn('systemctl enable', result.stdout)
        self.assertIn('systemctl daemon-reload', result.stdout)

    def test_network_permissions_are_limited_and_validated_before_install(self):
        destination = self.root / 'rule'
        result = self.shell('''command() {
  case "$2" in ip|rfkill|reboot) printf '/usr/sbin/%s\n' "$2" ;; esac
}
as_root() {
  case "$1" in
    visudo) printf 'validated\n' ;;
    install) cp "$8" "$RULE_OUTPUT" ;;
  esac
}
configure_network_recovery''', INSTALL_USER='user', RULE_OUTPUT=str(destination))
        self.assertEqual(result.returncode, 0, result.stderr)
        content = destination.read_text()
        self.assertIn('validated', result.stdout)
        self.assertIn('link set wlan0 down', content)
        self.assertIn('link set wlan0 up', content)
        self.assertIn('reboot ""', content)
        self.assertNotIn('NOPASSWD: ALL', content)
        self.assertNotIn('*', content)
        if shutil.which('visudo'):
            validation = subprocess.run(['visudo', '-cf', str(destination)],
                                        text=True, capture_output=True)
            self.assertEqual(validation.returncode, 0, validation.stderr)

    def test_failed_update_disables_service_across_reboot(self):
        result = self.shell('''as_root() { printf '%s\n' "$*"; }
service_is_installed() { return 0; }
SERVICE_WAS_ACTIVE=true
RUNTIME_MUTATED=true
trap finish_service_operation EXIT
exit 42''')
        self.assertEqual(result.returncode, 42)
        self.assertIn('systemctl stop alrotek-gateway.service', result.stdout)
        self.assertIn('systemctl disable alrotek-gateway.service', result.stdout)
        self.assertNotIn('systemctl start', result.stdout)

    def test_python_validation_uses_unprivileged_runner(self):
        result = self.shell('''run_as_install_user() { printf '%s\n' "$*" >> "$CALL_LOG"; }
require_supported_python /bin/sh''', CALL_LOG=str(self.root / 'calls'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len((self.root / 'calls').read_text().splitlines()), 2)

    def test_uninstall_does_not_delete_unit_when_stop_fails(self):
        result = self.shell('''service_is_installed() { return 0; }
as_root() {
  if [ "$1" = systemctl ]; then return 1; fi
  printf 'UNEXPECTED_DELETE\n'
}
remove_systemd_service''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('UNEXPECTED_DELETE', result.stdout)


if __name__ == '__main__':
    unittest.main()
