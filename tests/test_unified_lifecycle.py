"""Offline migration and native recovery barrier fixtures; no radio commands."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / 'modules/mt6639-hotspot'
BOOT_A = '11111111-1111-4111-8111-111111111111'
BOOT_B = '22222222-2222-4222-8222-222222222222'


class UnifiedLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.adb = self.root / 'adb'
        self.mod = self.adb / 'modules/mt6639-hotspot'
        (self.mod / 'bin').mkdir(parents=True)
        self.boot = self.root / 'boot'
        self.boot.write_text(BOOT_A + '\n')
        self.shims = self.root / 'shims'
        self.shims.mkdir()
        self.env = dict(os.environ, PATH=str(self.shims) + ':' + os.environ['PATH'])
        self.script(self.shims / 'id', 'case "$1" in -u) echo 0;; -Z) echo u:r:ksu:s0;; esac')
        self.script(self.shims / 'stat', '/usr/bin/stat "$@" | sed "s/^$(/usr/bin/id -u):/0:/; s/^$(/usr/bin/id -u)$/0/"')
        for name in ('cmd', 'settings', 'runcon', 'reboot', 'kill'):
            self.script(self.shims / name, 'exit 99')
        for name in ('unified-guard.sh', 'radio-teardown.sh'):
            text = (MOD / 'bin' / name).read_text()
            text = text.replace('/data/adb', str(self.adb)).replace('/proc/sys/kernel/random/boot_id', str(self.boot))
            (self.mod / 'bin' / name).write_text(text)

    def script(self, path, body):
        path.write_text('#!/bin/sh\n' + body + '\n')
        path.chmod(0o755)

    def guard(self, op='check'):
        return subprocess.run(['sh', str(self.mod / 'bin/unified-guard.sh'), str(self.mod), op],
                              env=self.env, capture_output=True, text=True)

    def test_install_is_inert_and_requires_different_kernel_boot(self):
        self.assertEqual(self.guard('install').returncode, 0)
        marker = self.mod / '.unified-install-boot'
        self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
        self.assertIn('unified_reboot_required', self.guard().stderr)
        self.boot.write_text(BOOT_B + '\n')
        self.assertEqual(self.guard().returncode, 0)

    def test_any_legacy_lifecycle_directory_blocks_install_and_activation(self):
        for parent in ('modules', 'modules_update'):
            for marker in ('disable', 'remove'):
                with self.subTest(parent=parent, marker=marker):
                    legacy = self.adb / parent / 'mt6639-6g'
                    legacy.mkdir(parents=True)
                    (legacy / marker).touch()
                    self.assertIn('legacy_six_module_present', self.guard('install').stderr)
                    self.assertFalse((self.mod / '.unified-install-boot').exists())
                    (legacy / marker).unlink()
                    legacy.rmdir()
        legacy = self.adb / 'modules/mt6639-6g'
        legacy.symlink_to(self.root / 'missing')
        self.assertIn('legacy_six_module_present', self.guard().stderr)

    def test_absent_corrupt_and_symlink_install_records_rejected(self):
        self.assertIn('unified_install_record_invalid', self.guard().stderr)
        record = self.mod / '.unified-install-boot'
        record.write_text('not-a-boot\n')
        self.assertIn('unified_install_record_invalid', self.guard().stderr)
        record.unlink()
        record.symlink_to(self.boot)
        self.assertIn('unified_install_record_invalid', self.guard('install').stderr)
        self.assertEqual(self.boot.read_text(), BOOT_A + '\n')

    def teardown(self, *args, state='idle', stop_rc=0, status_rc=0, verify_rc=0):
        work = self.adb / 'mt6639-hotspot'
        work.mkdir(exist_ok=True)
        (work / 'action.lock').touch(mode=0o600)
        self.script(self.mod / 'bin/verify-module.sh', f'exit {verify_rc}')
        self.script(self.mod / 'bin/control.sh', f'''
case "$2" in
stop) echo stop >> '{self.root}/calls'; exit {stop_rc};;
status) echo status >> '{self.root}/calls'; echo state={state}; exit {status_rc};;
*) exit 99;;
esac''')
        return subprocess.run(['sh', str(self.mod / 'bin/radio-teardown.sh'), *args],
                              env=self.env, capture_output=True, text=True)

    def test_barrier_stops_then_checks_idle_and_never_calls_six(self):
        self.assertEqual(self.teardown().returncode, 0)
        self.assertEqual((self.root / 'calls').read_text().splitlines(), ['stop', 'status'])
        (self.root / 'calls').unlink()
        self.assertEqual(self.teardown('check').returncode, 0)
        self.assertEqual((self.root / 'calls').read_text().splitlines(), ['status'])

    def test_barrier_refuses_failed_stop_status_or_integrity(self):
        for kwargs in ({'stop_rc': 71}, {'state': 'unresolved'}, {'status_rc': 3}, {'verify_rc': 3}):
            with self.subTest(kwargs=kwargs):
                self.assertNotEqual(self.teardown(**kwargs).returncode, 0)


if __name__ == '__main__':
    unittest.main()
