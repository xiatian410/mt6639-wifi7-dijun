"""Run the real controller against synthetic proc/net/tether fixtures, never radios."""
import fcntl
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / 'modules/mt6639-hotspot'
BOOT_A = '11111111-1111-4111-8111-111111111111'
BOOT_B = '22222222-2222-4222-8222-222222222222'
IDLE = '    Upstream wanted: false\n    Current upstream interface(s): null\n'


class CrossBootSessionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='hotspot-retirement-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.mod = self.root / 'module'
        (self.mod / 'bin').mkdir(parents=True)
        self.work = self.root / 'work'
        self.work.mkdir(mode=0o700)
        self.session = self.work / 'session'
        self.session.mkdir(mode=0o700)
        self.local = self.root / 'data/local/tmp'
        self.local.mkdir(parents=True)
        self.task = self.local / 'mt6639-native-ap-fixture'
        self.task.mkdir(mode=0o700)
        self.proc = self.root / 'proc'
        (self.proc / '1').mkdir(parents=True)
        (self.proc / '1/cmdline').write_bytes(b'/system/bin/init\0')
        (self.proc / '1/exe').symlink_to('/system/bin/init')
        self.net = self.root / 'net'
        self.net.mkdir()
        self.boot = self.root / 'boot'
        self.boot.write_text(BOOT_B + '\n')
        for name, value in {'task': str(self.task), 'boot': BOOT_A, 'pid': '4242',
                            'runner.start': '1234', 'band': '6g', 'width': '20',
                            '.evidence': 'keep-hidden', 'extra': 'keep-extra'}.items():
            self.private(self.session / name, value + '\n')
        self.private(self.work / 'state', 'unresolved\n')
        self.private(self.work / 'action.lock', 'lock evidence\n')
        self.private(self.task / 'ap.key', 'synthetic-only-password\n')
        self.private(self.task / 'recovery.rc', '7\n')
        self.script(self.task / 'softap_native_once.sh', 'echo forbidden >> "$FORBIDDEN"; exit 99')
        self.stub = self.root / 'stub'
        self.stub.mkdir()
        self.tether = self.root / 'tether'
        self.tether.write_text(IDLE)
        self.links = self.root / 'links'
        self.links.write_text('1: lo: <LOOPBACK,UP> mtu 65536\n2: wlan0: <UP> mtu 1500\n')
        self.env = dict(os.environ, PATH=str(self.stub) + ':' + os.environ['PATH'],
                        WORK=str(self.work), SESSION=str(self.session), TETHER=str(self.tether),
                        LINKS=str(self.links), CALLS=str(self.root / 'calls'),
                        FORBIDDEN=str(self.root / 'forbidden'))
        self.script(self.stub / 'id', 'case "$1" in -Z) echo u:r:ksu:s0;; *) echo 0;; esac')
        self.script(self.stub / 'stat', f'''
[ "${{DEVICE_STAT_FAIL:-0}}" = 0 ] || [ "$2" != %d ] || exit 1
case "$2" in %u) echo "${{OWNER_OVERRIDE:-0}}";; *) exec {shutil.which('stat')} "$@";; esac''')
        self.script(self.stub / 'ip', '''
echo ip >> "$CALLS"
flock -n "$WORK/action.lock" true && exit 98
[ "${IP_RC:-0}" = 0 ] || exit "$IP_RC"
cat "$LINKS"''')
        self.script(self.stub / 'dumpsys', '''
echo dumpsys >> "$CALLS"
flock -n "$WORK/action.lock" true && exit 98
cat "$TETHER"
exit "${TETHER_RC:-0}"''')
        self.script(self.stub / 'cat', f'''
[ "$1" != "${{CAT_FAIL:-}}" ] || exit 1
exec {shutil.which('cat')} "$@"''')
        self.script(self.stub / 'tr', f'''
[ "${{TR_FAIL:-0}}" = 0 ] || exit 1
exec {shutil.which('tr')} "$@"''')
        self.script(self.stub / 'mv', f'''
if [ "$1" = "$SESSION" ]; then
    flock -n "$WORK/action.lock" true && exit 98
    [ "${{ARCHIVE_FAIL:-0}}" = 0 ] || exit 1
fi
[ "${{STATE_FAIL:-0}}" = 0 ] || [ "$1" != -f ] || exit 1
exec {shutil.which('mv')} "$@"''')
        for name in ('cmd', 'settings', 'reboot', 'kill', 'app_process'):
            self.script(self.stub / name, 'echo forbidden >> "$FORBIDDEN"; exit 99')
        self.script(self.mod / 'bin/status_snapshot.sh', 'echo "snapshot $2 ${3:-}" >> "$CALLS"')
        self.script(self.mod / 'bin/status-card.sh', 'exit 0')
        source = (MOD / 'bin/control.sh').read_text()
        for before, after in [('/data/adb/modules/mt6639-hotspot', str(self.mod)),
                              ('/data/adb/mt6639-hotspot', str(self.work)),
                              ('/data/local', str(self.root / 'data/local')),
                              ('in /data ', 'in ' + str(self.root / 'data') + ' '),
                              ('/proc/sys/kernel/random/boot_id', str(self.boot)),
                              ('/proc/', str(self.proc) + '/'),
                              ('/sys/class/net/', str(self.net) + '/')]:
            source = source.replace(before, after)
        self.controller = self.mod / 'bin/control.sh'
        self.controller.write_text(source)
        self.saved_session = self.contents(self.session)
        self.saved_task = self.contents(self.task)

    @staticmethod
    def private(path, text):
        path.write_text(text)
        path.chmod(0o600)

    @staticmethod
    def script(path, text):
        path.write_text('#!/bin/sh\n' + text + '\n')
        path.chmod(0o700)

    @staticmethod
    def contents(path):
        return {p.name: (p.read_bytes(), p.stat().st_mode & 0o777, p.stat().st_ino)
                for p in path.iterdir()}

    def run_control(self, op='reconcile', **env):
        result = subprocess.run([os.environ.get('MT6639_TEST_SHELL', 'sh'),
                                 str(self.controller), str(self.mod), op],
                                env=dict(self.env, **env), capture_output=True,
                                text=True, timeout=15)
        self.assertFalse((self.root / 'forbidden').exists(), result.stdout + result.stderr)
        return result

    def assert_retained(self):
        self.assertEqual(self.contents(self.session), self.saved_session)
        self.assertEqual(self.contents(self.task), self.saved_task)
        self.assertEqual((self.work / 'state').read_text(), 'unresolved\n')
        self.assertFalse(list(self.work.glob('history/*/session')))

    def test_retirement_stop_recover_and_reconcile_preserve_every_record(self):
        for op in ('stop', 'recover', 'reconcile'):
            with self.subTest(op=op):
                r = self.run_control(op)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertIn('reason=cross_boot_session_retired', r.stdout)
                archived, = self.work.glob('history/*/session')
                self.assertEqual(self.contents(archived), self.saved_session)
                self.assertEqual(self.contents(self.task), self.saved_task)
                self.assertEqual((self.work / 'action.lock').read_text(), 'lock evidence\n')
                self.assertEqual((self.work / 'state').read_text(), 'idle\n')
                self.assertEqual(self.work.joinpath('history').stat().st_mode & 0o777, 0o700)
                self.assertFalse(self.session.exists())
                archived.rename(self.session)
                shutil.rmtree(self.work / 'history')
                self.private(self.work / 'state', 'unresolved\n')

    def test_missing_task_is_retired_without_executing_old_scripts(self):
        shutil.rmtree(self.task)
        r = self.run_control('stop')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        archived, = self.work.glob('history/*/session')
        self.assertEqual(self.contents(archived), self.saved_session)
        self.assertFalse(self.task.exists())

    def test_same_boot_reconcile_refuses_and_preserves_authority(self):
        self.boot.write_text(BOOT_A + '\n')
        r = self.run_control()
        self.assertEqual(r.returncode, 78, r.stderr)
        self.assertIn('detail=same_boot', r.stderr)
        self.assert_retained()

    def test_same_boot_stop_retains_existing_no_effect_behavior(self):
        self.boot.write_text(BOOT_A + '\n')
        # Existing same-boot cleanup does not use retirement or require dumpsys.
        r = self.run_control('stop', TETHER_RC='99')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('reason=no_effect_terminal', r.stdout)
        self.assertNotIn('cross_boot_session_retired', r.stdout)
        self.assertEqual((self.task / 'cleanup.request').read_bytes(), b'')

    def test_malformed_missing_unreadable_boot_records_refuse(self):
        for which in (self.boot, self.session / 'boot'):
            original = which.read_bytes()
            for value in ('', 'not-a-uuid\n', BOOT_A + '\n' + BOOT_B + '\n', 'missing'):
                with self.subTest(which=which.name, value=value):
                    if value == 'missing':
                        which.unlink(missing_ok=True)
                    else:
                        self.private(which, value)
                    r = self.run_control('stop')
                    self.assertEqual(r.returncode, 78, r.stdout + r.stderr)
                    self.assertTrue(self.session.is_dir())
                    self.assertFalse(list(self.work.glob('history/*/session')))
            self.private(which, original.decode())
        for which in (self.boot, self.session / 'boot', self.session / 'task'):
            r = self.run_control('recover', CAT_FAIL=str(which))
            self.assertEqual(r.returncode, 78, r.stdout + r.stderr)
            self.assertTrue(self.session.is_dir())

    def test_symlink_authority_paths_and_hardlinks_refuse(self):
        for path in (self.session / 'boot', self.session / 'task', self.session / 'extra',
                     self.session, self.task, self.work / 'state', self.work / 'action.lock',
                     self.work, self.local):
            with self.subTest(path=path):
                target = self.root / 'saved-target'
                path.rename(target)
                path.symlink_to(target, target_is_directory=target.is_dir())
                before = target.stat().st_ino
                r = self.run_control('recover')
                self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertEqual(target.stat().st_ino, before)
                path.unlink()
                target.rename(path)
                self.assert_retained()
        for name in ('history', 'control.log'):
            path = self.work / name
            path.symlink_to(self.root / 'missing')
            self.assertEqual(self.run_control().returncode, 78)
            self.assert_retained()
            path.unlink()
        os.link(self.session / 'extra', self.root / 'extra-link')
        self.assertEqual(self.run_control().returncode, 78)
        self.assert_retained()

    def test_nonprivate_or_foreign_authority_refuses(self):
        for path in (self.session, self.session / 'boot', self.task, self.work):
            with self.subTest(path=path):
                old = path.stat().st_mode & 0o777
                path.chmod(0o755 if path.is_dir() else 0o644)
                self.assertEqual(self.run_control().returncode, 78)
                path.chmod(old)
                self.assert_retained()
        self.assertEqual(self.run_control(OWNER_OVERRIDE='12345').returncode, 77)
        self.assert_retained()

    def test_query_failure_empty_ambiguous_or_active_tether_refuses(self):
        outputs = ['', 'unrecognized\n', '    Upstream wanted: false\n',
                   IDLE + '    Upstream wanted: true\n', IDLE + IDLE,
                   IDLE.replace('null', '[wlan0]'),
                   IDLE + '    mtap0 - AvailableState - lastError = 0\n',
                   IDLE + '    usb0 - TetheredState - lastError = 0\n',
                   IDLE + '    wlan1 - LocalHotspotState - lastError = 0\n',
                   IDLE + 'Permission denied\n']
        for output in outputs:
            with self.subTest(output=output):
                self.tether.write_text(output)
                self.assertEqual(self.run_control().returncode, 78)
                self.assert_retained()
        self.tether.write_text(IDLE)
        self.assertEqual(self.run_control(TETHER_RC='1').returncode, 78)
        self.assert_retained()

    def test_interface_presence_and_failed_untrustworthy_enumeration_refuse(self):
        original = self.links.read_text()
        for output in ('', 'unknown\n', original + '3: mtap0: <UP> mtu 1500\n',
                       original + '3: mtap1@if4: <UP> mtu 1500\n'):
            self.links.write_text(output)
            self.assertEqual(self.run_control().returncode, 78)
            self.assert_retained()
        self.links.write_text(original)
        self.assertEqual(self.run_control(IP_RC='1').returncode, 78)
        (self.net / 'mtap0').mkdir()
        self.assertEqual(self.run_control().returncode, 78)
        self.assert_retained()

    def test_live_processes_and_read_failures_refuse_independent_of_boot_or_pid(self):
        process = self.proc / '9876'
        process.mkdir()
        for command in (f'sh {self.task}/softap_native_once.sh {self.task} run-tether',
                        f'sh {self.task}/softap_native_once.sh {self.task} guardian',
                        f'{self.task}/hostapd -ddd', '/vendor/bin/hw/hostapd',
                        '/other/mt6639-native-ap-new/softap_native_once.sh guardian'):
            with self.subTest(command=command):
                (process / 'cmdline').write_bytes(command.replace(' ', '\0').encode())
                self.assertEqual(self.run_control('stop').returncode, 78)
                self.assert_retained()
        (process / 'cmdline').unlink()
        self.assertEqual(self.run_control().returncode, 78)
        process.rmdir()
        self.assertEqual(self.run_control(TR_FAIL='1').returncode, 78)
        self.assert_retained()

    def test_executable_identity_kernel_threads_and_unknown_processes(self):
        process = self.proc / '9876'
        process.mkdir()
        (process / 'cmdline').write_bytes(b'innocent-name\0')
        (process / 'exe').symlink_to(str(self.task / 'hostapd'))
        self.assertEqual(self.run_control().returncode, 78)
        (process / 'exe').unlink()
        self.assertEqual(self.run_control().returncode, 78)
        (process / 'cmdline').write_bytes(b'')
        (process / 'stat').write_text('9876 (zombie) Z 1 2 3 4 5 0\n')
        self.assertEqual(self.run_control().returncode, 78)
        self.assert_retained()
        (process / 'stat').write_text('9876 (kernel worker) I 0 0 0 0 0 2097152\n')
        self.assertEqual(self.run_control().returncode, 0)

    def test_state_publish_failure_rolls_back_for_retry(self):
        self.assertEqual(self.run_control(STATE_FAIL='1').returncode, 74)
        self.assert_retained()
        self.assertFalse(list(self.work.glob('.retired-state.*')))
        self.assertEqual(self.run_control().returncode, 0)

    def test_lock_contention_and_archive_failure_preserve_evidence(self):
        with (self.work / 'action.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.run_control().returncode, 75)
            self.assertFalse((self.root / 'calls').exists())
            self.assert_retained()
        self.assertEqual(self.run_control(DEVICE_STAT_FAIL='1').returncode, 74)
        self.assert_retained()
        self.assertEqual(self.run_control(ARCHIVE_FAIL='1').returncode, 74)
        self.assert_retained()
        self.assertFalse(list(self.work.glob('.retired-state.*')))
        self.assertEqual(self.run_control().returncode, 0)

    def test_status_under_existing_lock_never_retires_session(self):
        with (self.work / 'action.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            r = self.run_control('status')
            # Existing status returns 1 without status.active; do not turn it
            # into a lock acquisition or a cross-boot cleanup operation.
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertIn('state=unresolved', r.stdout)
            self.assertNotIn('cross_boot_session_retired', r.stdout)
            self.assert_retained()

    def test_real_service_reconciles_before_snapshot_and_worker(self):
        service = self.mod / 'service.sh'
        service.write_text((MOD / 'service.sh').read_text())
        self.private(self.mod / 'config.conf', 'ENABLE_AT_BOOT=0\n')
        for name in ('verify-module.sh', 'unified-guard.sh'):
            self.script(self.mod / 'bin' / name, 'exit 0')
        self.script(self.mod / 'bin/request_worker.sh', 'echo worker >> "$CALLS"')
        # A boot-time tether service failure must not initialize idle or start
        # the bridge. Retrying the hook with trustworthy inputs is safe.
        for failed in (True, False):
            self.root.joinpath('calls').unlink(missing_ok=True)
            r = subprocess.run([os.environ.get('MT6639_TEST_SHELL', 'sh'), str(service)],
                               env=dict(self.env, TETHER_RC='1' if failed else '0'),
                               capture_output=True, text=True, timeout=15)
            calls = self.root.joinpath('calls').read_text().splitlines()
            if failed:
                self.assertEqual(r.returncode, 78, r.stdout + r.stderr)
                self.assertFalse(any(c.startswith(('snapshot', 'worker')) for c in calls))
                self.assert_retained()
            else:
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertEqual(calls[-2:], ['snapshot init ', 'worker'])
                self.assertFalse(self.session.exists())

    def test_absent_session_reconcile_is_noop(self):
        shutil.rmtree(self.session)
        r = self.run_control()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse((self.root / 'calls').exists())
        self.assertFalse((self.work / 'history').exists())


if __name__ == '__main__':
    unittest.main()
