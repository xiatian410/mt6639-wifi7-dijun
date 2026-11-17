"""Offline lifecycle ordering and migration-gate integration; no device I/O."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / 'modules/mt6639-hotspot'


class UnifiedHotspotWiringTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='unified-wiring-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.mod = self.root / 'module'
        self.bin = self.mod / 'bin'
        self.bin.mkdir(parents=True)
        self.stub = self.root / 'stub'
        self.stub.mkdir()
        self.log = self.root / 'calls'
        self.env = dict(os.environ, PATH=str(self.stub) + ':' + os.environ['PATH'],
                        CALLS=str(self.log))
        self.script(self.stub / 'id', 'case "$1" in -Z) echo u:r:ksu:s0 ;; *) echo 0 ;; esac')
        self.script(self.bin / 'verify-module.sh', 'echo verify >> "$CALLS"; exit "${VERIFY_RC:-0}"')
        self.script(self.bin / 'unified-guard.sh',
                    'echo guard >> "$CALLS"; echo "REJECT unified_reboot_required" >&2; exit "${GUARD_RC:-0}"')
        self.script(self.bin / 'status_snapshot.sh', 'echo snapshot >> "$CALLS"')
        self.script(self.bin / 'control.sh', 'echo "control $2" >> "$CALLS"; exit "${RECONCILE_RC:-0}"')
        self.script(self.bin / 'request_worker.sh',
                    'echo "worker $2" >> "$CALLS"; exit "${WORKER_RC:-0}"')
        self.script(self.bin / 'radio-control.sh', 'echo "radio $2 ${3:-}" >> "$CALLS"')
        self.script(self.bin / 'radio-teardown.sh',
                    'echo "teardown $1" >> "$CALLS"; exit "${TEARDOWN_RC:-0}"')
        sixbin = self.mod / 'six/bin'
        sixbin.mkdir(parents=True)
        self.script(sixbin / 'control.sh', 'echo "six $2" >> "$CALLS"; exit "${SIX_RC:-0}"')
        (self.mod / 'config.conf').write_text('ENABLE_AT_BOOT=${AUTOSTART:-0}\nBAND=${TEST_BAND:-6g}\nWIDTH=80\n')
        for name in ('service.sh', 'uninstall.sh'):
            (self.mod / name).write_text((MOD / name).read_text())

    @staticmethod
    def script(path, body):
        path.write_text('#!/bin/sh\n' + body + '\n')
        path.chmod(0o755)

    def run_hook(self, name, **env):
        self.log.unlink(missing_ok=True)
        r = subprocess.run(['sh', str(self.mod / name)], env=dict(self.env, **env),
                           capture_output=True, text=True, timeout=10)
        calls = self.log.read_text().splitlines() if self.log.exists() else []
        return r, calls

    def test_service_verifies_guards_then_initializes_without_independent_six_start(self):
        r, calls = self.run_hook('service.sh')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(calls, ['verify', 'guard', 'control reconcile', 'snapshot', 'worker start'])
        r, calls = self.run_hook('service.sh', AUTOSTART='1')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(calls[-1], 'radio start 80')
        r, calls = self.run_hook('service.sh', AUTOSTART='1', TEST_BAND='5g')
        self.assertEqual(r.returncode, 64)
        self.assertFalse(any(c.startswith(('radio ', 'six ')) for c in calls))
        for env, expected in [({'VERIFY_RC': '69'}, ['verify']),
                              ({'GUARD_RC': '73'}, ['verify', 'guard']),
                              ({'RECONCILE_RC': '78'}, ['verify', 'guard', 'control reconcile'])]:
            r, calls = self.run_hook('service.sh', **env)
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(calls, expected)

    def test_uninstall_stops_worker_ap_then_six_and_preserves_failure(self):
        journal = self.root / 'journal'
        journal.write_text('authority\n')
        r, calls = self.run_hook('uninstall.sh', GUARD_RC='73')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(calls, ['worker stop', 'teardown stop', 'six disable'])
        for env, expected in [({'WORKER_RC': '1'}, ['worker stop']),
                              ({'TEARDOWN_RC': '73'}, ['worker stop', 'teardown stop']),
                              ({'SIX_RC': '70'}, ['worker stop', 'teardown stop', 'six disable'])]:
            r, calls = self.run_hook('uninstall.sh', **env)
            self.assertNotEqual(r.returncode, 0)
            self.assertEqual(calls, expected)
            self.assertIn('journals preserved', r.stderr)
        self.assertEqual(journal.read_text(), 'authority\n')

    def test_direct_control_mutations_guard_before_work_directory_creation(self):
        work = self.root / 'work'
        controller = self.mod / 'control.sh'
        controller.write_text((MOD / 'bin/control.sh').read_text().replace(
            '/data/adb/modules/mt6639-hotspot', str(self.mod)).replace(
            '/data/adb/mt6639-hotspot', str(work)))
        for op in ('start', 'toggle', 'c02-24g'):
            r = subprocess.run(['sh', str(controller), str(self.mod), op],
                               env=dict(self.env, GUARD_RC='73'), capture_output=True,
                               text=True, timeout=10)
            self.assertEqual(r.returncode, 73, r.stderr)
            self.assertIn('unified_reboot_required', r.stderr)
            self.assertFalse(work.exists())

    def test_recovery_checker_receives_explicit_embedded_directory(self):
        source = (ROOT / 'tools/twt_recover.sh').read_text()
        section = source[source.index('if [ -n "$SIX" ]; then\n    timeout'):source.index('\nrc=$?', source.index('log target_ready'))]
        checker = self.root / 'checker'
        self.script(checker, 'printf "%s\\n" "$@"')
        for six, expected in [('', ['active']),
                              ('/data/adb/modules/mt6639-hotspot/six',
                               ['active', '/data/adb/modules/mt6639-hotspot/six'])]:
            r = subprocess.run(['sh', '-c', 'SIX=$1; CHECKER=$2; V=$3; ' + section,
                                'sh', six, str(checker), str(self.root)], capture_output=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual((self.root / 'checker.txt').read_text().splitlines(), expected)
        for name in ('softap_once.sh', 'softap_native_once.sh'):
            caller = (ROOT / 'tools' / name).read_text()
            self.assertNotIn('/data/adb/modules/mt6639-6g', caller)
            self.assertIn('"$SIX" > "$D/network.', caller)

    def test_raw_softap_setup_guard_precedes_claim_and_recovery_stays_exempt(self):
        task = self.root / 'mt6639-ap-fixture'
        task.mkdir(mode=0o700)
        self.script(self.stub / 'getenforce', 'echo Enforcing')
        runner = task / 'softap_once.sh'
        runner.write_text((ROOT / 'tools/softap_once.sh').read_text().replace(
            '/data/local/tmp/mt6639-ap-', str(self.root / 'mt6639-ap-')).replace(
            '/data/adb/modules/mt6639-hotspot', str(self.mod)))
        for mode in ('run', 'run-24g', 'run-5g'):
            r = subprocess.run(['sh', str(runner), str(task), mode],
                               env=dict(self.env, GUARD_RC='73'), capture_output=True, text=True)
            self.assertEqual(r.returncode, 73, r.stderr)
            self.assertFalse((task / 'owner.lock').exists())
        self.log.unlink()
        # Existing successful recovery is idempotent, even if new starts reject.
        (task / 'recovery.rc').write_text('0\n')
        r = subprocess.run(['sh', str(runner), str(task), 'recover'],
                           env=dict(self.env, GUARD_RC='73'), capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.log.exists())

    def test_recovery_helper_rejects_unapproved_owner_before_creating_journal(self):
        task = self.root / 'task'
        task.mkdir()
        checker = self.root / 'checker'
        self.script(checker, 'exit 0')
        for owner in ('/data/adb/modules/mt6639-6g', '/tmp/six',
                      '/data/adb/modules/mt6639-hotspot/six'):
            # Even the approved owner cannot be paired with an arbitrary checker.
            r = subprocess.run(['sh', str(ROOT / 'tools/twt_recover.sh'), 'check',
                                str(task), 'boot', 'fixture', '6135',
                                '02:00:00:00:00:01', '198.51.100.1', str(checker), owner],
                               env=self.env, capture_output=True, text=True)
            self.assertEqual(r.returncode, 64, r.stderr)
            self.assertFalse((task / 'verification').exists())

    def test_embedded_recovery_budgets_leave_standalone_limits_unchanged(self):
        six = ROOT / 'modules/mt6639-6g/bin'
        control = (six / 'control.sh').read_text()
        block = control[control.index('mutation_timeout=180'):control.index('case "$operation" in\n    refresh)')]
        native = (six / 'native.sh').read_text()
        wait = native[native.index('wait_terminal() {'):native.index('\nnative_recover_retry() {')]
        for embedded, timeout, ticks in [('0', '180', '100'), ('1', '1260', '600')]:
            r = subprocess.run(['sh', '-c', 'MODULE_EMBEDDED=$1; ' + block +
                                '\nprintf "%s\\n" "$mutation_timeout"', 'sh', embedded],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.strip(), timeout)
            harness = ('MODULE_EMBEDDED=$1; grep() { return 1; }; guardian_alive() { return 0; }; '
                       'sleep() { :; }; ' + wait + '\nwait_terminal fixture; printf "%s\\n" "$i"')
            r = subprocess.run(['sh', '-c', harness, 'sh', embedded], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.strip(), ticks)
        self.assertEqual(control.count('timeout "$mutation_timeout" sh "$MODDIR/bin/native.sh"'), 2)
        self.assertIn('timeout 90 sh "$MODDIR/bin/refresh-6g.sh"', control)

    def test_builder_requires_explicit_seventh_native_argument(self):
        builder = ROOT / 'tools/build_hotspot_module.sh'
        r = subprocess.run(['sh', str(builder), 'a', 'b', 'c', 'd', 'e', ''],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 64)
        self.assertIn('UNIFIED_MOUNT_TXN', r.stderr)


if __name__ == '__main__':
    unittest.main()
