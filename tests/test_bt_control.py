"""Execute production Bluetooth entrypoints; only Android I/O/paths are doubled."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
INITIAL = '22f2e2ac8c036f7716e792f1fa54d7f5c3dd53754cb3c01db93ee3981cd34339'
STABLE = '1a5ae65ccd8621c03ca5a6a035979eac74025c3ecdda19dd84f1bbd53162983e'
BOOT = '11111111-1111-4111-8111-111111111111'


class BluetoothSnapshotTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='mt6639-bt-control-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.module = self.root / 'module'
        shutil.copytree(REPO / 'modules/mt6639-bt', self.module)
        self.script = self.module / 'bin/control.sh'
        self.base = self.root / 'state'
        self.state = self.base / BOOT
        self.boot = self.root / 'boot'
        self.boot.write_text(BOOT + '\n')
        self.script.write_text(self.script.read_text().replace(
            'BASE=/data/adb/mt6639-bt', 'BASE=' + str(self.base)).replace(
            '/proc/sys/kernel/random/boot_id', str(self.boot)))
        # Real glob discovery and read-error handling, within a private fixture.
        self.apex = self.root / 'apex'
        self.apk = self.apex / 'app/Bluetooth@new-build/Bluetooth.apk'
        self.apk.parent.mkdir(parents=True)
        self.apk.write_text('fixture, not an original APK')
        compat = self.module / 'bin/compat.sh'
        compat.write_text(compat.read_text().replace('/apex/com.android.bt', str(self.apex)))
        self.props = self.root / 'properties'
        self.props.mkdir()
        self.writes = self.root / 'writes'
        self.keys = [line for line in self.script.read_text().split("KEYS='")[1].split("'")[0].splitlines()]
        stub = self.root / 'stub'
        stub.mkdir()
        commands = {
            'id': '#!/bin/sh\nif [ "$1" = -Z ]; then echo u:r:ksu:s0; else echo 0; fi\n',
            'getenforce': '#!/bin/sh\necho Enforcing\n',
            'stat': '''#!/bin/sh
if [ "$1" = -c ] && [ "$2" = %u ]; then echo "${OWNER:-0}"; else exec REAL_STAT "$@"; fi
'''.replace('REAL_STAT', shutil.which('stat')),
            'flock': '#!/usr/bin/python3\nimport fcntl,sys\nfcntl.flock(int(sys.argv[-1]),fcntl.LOCK_EX|fcntl.LOCK_NB)\n',
            'getprop': '''#!/bin/sh
case "$1" in
 ro.product.device) echo dijun ;;
 ro.build.version.sdk) echo "${SDK:-37}" ;;
 ro.build.fingerprint) echo Xiaomi/dijun/dijun:17/new/OS4-new:user/release-keys ;;
 ro.bluetooth.leaudio_offload.supported) echo "${OFFLOAD:-true}" ;;
 persist.bluetooth.leaudio_offload.disabled) echo false ;;
 bluetooth.profile.csip.set_coordinator.enabled)
  if [ "${BAD_BASELINE:-0}" = 1 ]; then echo invalid; else cat "$PROPS/$1" 2>/dev/null || echo false; fi ;;
 *) cat "$PROPS/$1" 2>/dev/null || echo false ;;
esac
''',
            'setprop': '''#!/bin/sh
if [ "$1" = "${FAIL_KEY:-}" ] && [ "$2" = "${FAIL_VALUE:-true}" ]; then exit 1; fi
echo "$1 $2" >> "$WRITES"
printf '%s\\n' "$2" > "$PROPS/$1"
''',
            'sha256sum': '''#!/bin/sh
case "$1" in
 "$APEX"/*)
  [ "${READ_FAIL:-0}" = 0 ] || exit 1
  echo "${APK_SHA}  $1" ;;
 *) exec REAL_SHA "$@" ;;
esac
'''.replace('REAL_SHA', shutil.which('sha256sum')),
            'runcon': '''#!/bin/sh
[ "$1" = u:r:shell:s0 ] && [ "$2" = sh ] && [ "$3" = -c ] &&
 [ "$4" = 'settings get global bluetooth_on' ] || exit 90
printf '%s\\n' "${SETTING:-1}"
exit "${SETTING_RC:-0}"
''',
        }
        for name, source in commands.items():
            path = stub / name
            path.write_text(source)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=str(stub) + ':' + os.environ['PATH'],
                        PROPS=str(self.props), WRITES=str(self.writes),
                        APEX=str(self.apex), APK_SHA=INITIAL)

    def run_op(self, op, **extra):
        return subprocess.run(['sh', str(self.script), op], env=dict(self.env, **extra),
                              text=True, capture_output=True, timeout=12)

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def write_count(self):
        return len(self.writes.read_text().splitlines()) if self.writes.exists() else 0

    def test_failed_preparation_is_not_published_and_can_retry(self):
        failed = self.run_op('enable', BAD_BASELINE='1')
        self.assertNotEqual(failed.returncode, 0)
        self.assertFalse(self.state.exists(), failed.stderr)
        self.assertEqual(self.write_count(), 0)
        self.assertTrue(list(self.base.glob('.prepare-*')))
        self.assert_ok(self.run_op('enable'))
        self.assertEqual((self.state / 'state').read_text(), 'active\n')
        self.assertEqual(self.write_count(), 6)
        self.assert_ok(self.run_op('restore'))
        self.assertTrue(all(p.read_text() == 'false\n' for p in self.props.iterdir()))

    def test_new_component_accepts_changed_ota_fingerprint(self):
        self.assert_ok(self.run_op('enable', APK_SHA=STABLE))
        status = self.run_op('status', APK_SHA=STABLE)
        self.assert_ok(status)
        self.assertIn('compatibility_profile=os4-stable compatibility_error=none', status.stdout)
        self.assertIn('bluetooth_on=1', status.stdout)
        self.assertEqual(self.write_count(), 6)

    def test_unknown_component_does_not_change_properties(self):
        r = self.run_op('enable', APK_SHA='0' * 64)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('unsupported_bluetooth_apk', r.stderr)
        self.assertEqual(self.write_count(), 0)

    def test_missing_apk(self):
        self.apk.unlink()
        r = self.run_op('enable')
        self.assertIn('missing_or_ambiguous_bluetooth_apk', r.stderr)
        self.assertEqual(self.write_count(), 0)

    def test_ambiguous_apk(self):
        alt = self.apex / 'app/Bluetooth@second/Bluetooth.apk'
        alt.parent.mkdir()
        alt.write_text('another fixture')
        self.assertIn('missing_or_ambiguous_bluetooth_apk', self.run_op('enable').stderr)
        self.assertEqual(self.write_count(), 0)

    def test_unreadable_apk_is_distinguished(self):
        self.assertIn('unreadable_bluetooth_apk', self.run_op('enable', READ_FAIL='1').stderr)
        self.assertEqual(self.write_count(), 0)

    def test_sdk_and_offload_guard(self):
        for extra in [dict(SDK='36'), dict(OFFLOAD='false')]:
            with self.subTest(extra=extra):
                self.assertNotEqual(self.run_op('enable', **extra).returncode, 0)
                self.assertEqual(self.write_count(), 0)

    def test_restore_after_apex_update_remains_available(self):
        self.assert_ok(self.run_op('enable'))
        self.assert_ok(self.run_op('restore', APK_SHA='0' * 64, SDK='38'))
        self.assertEqual((self.state / 'state').read_text(), 'restored\n')

    def test_restore_failure_marker_toggle_retries_restore(self):
        self.assert_ok(self.run_op('enable'))
        result = self.run_op('restore', FAIL_KEY=self.keys[1], FAIL_VALUE='false')
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertEqual((self.state / 'state').read_text(), 'restore_failed\n')
        self.assertEqual((self.props / self.keys[1]).read_text(), 'true\n')
        self.assert_ok(self.run_op('toggle'))
        self.assertEqual((self.state / 'state').read_text(), 'restored\n')
        self.assertTrue(all(p.read_text() == 'false\n' for p in self.props.iterdir()))

    def test_apply_failure_rolls_back_original_values(self):
        result = self.run_op('enable', FAIL_KEY=self.keys[2])
        self.assertEqual(result.returncode, 70, result.stderr)
        self.assertEqual((self.state / 'state').read_text(), 'restored\n')
        self.assertTrue(all(p.read_text() == 'false\n' for p in self.props.iterdir()))

    def test_mixed_baseline_preserved_and_enable_idempotent(self):
        (self.props / self.keys[0]).write_text('true\n')
        self.assert_ok(self.run_op('enable'))
        self.assert_ok(self.run_op('enable'))
        self.assertEqual(self.write_count(), 6)
        self.assert_ok(self.run_op('restore'))
        self.assertEqual((self.props / self.keys[0]).read_text(), 'true\n')
        self.assert_ok(self.run_op('restore'))
        self.assertEqual(self.write_count(), 11)

    def test_prepared_intent_can_be_restored(self):
        self.assert_ok(self.run_op('enable'))
        (self.state / 'state').write_text('prepared\n')
        self.assert_ok(self.run_op('toggle'))
        self.assertEqual((self.state / 'state').read_text(), 'restored\n')

    def test_foreign_values_and_corrupt_snapshot_no_overwrite(self):
        self.assert_ok(self.run_op('enable'))
        (self.props / self.keys[0]).write_text('foreign\n')
        self.assertEqual(self.run_op('restore').returncode, 73)
        self.assertEqual(self.write_count(), 6)
        (self.state / 'before.tsv').write_text('corrupt\n')
        self.assertNotEqual(self.run_op('restore').returncode, 0)
        self.assertEqual(self.write_count(), 6)

    def test_no_cross_boot_snapshot_replay(self):
        self.assert_ok(self.run_op('enable'))
        self.boot.write_text('22222222-2222-4222-8222-222222222222\n')
        self.assert_ok(self.run_op('restore'))
        self.assertEqual(self.write_count(), 6)
        self.assertEqual((self.state / 'state').read_text(), 'active\n')

    def test_invalid_boot_and_owner_and_symlink_rejected(self):
        self.boot.write_text('---\n')
        self.assertIn('invalid_boot_id', self.run_op('enable').stderr)
        self.boot.write_text(BOOT + '\n')
        self.assertIn('state_root_owner', self.run_op('enable', OWNER='2000').stderr)
        self.assertEqual(self.write_count(), 0)
        target = self.root / 'target'
        target.write_text('untouched')
        (self.base / 'control.lock').symlink_to(target)
        self.assertIn('lock_symlink', self.run_op('enable').stderr)
        self.assertEqual(target.read_text(), 'untouched')

    def test_binder_failure_or_invalid_output_is_unknown(self):
        for extra in [dict(SETTING_RC='1'), dict(SETTING='service error'), dict(SETTING='null')]:
            with self.subTest(extra=extra):
                r = self.run_op('status', **extra)
                self.assert_ok(r)
                self.assertIn('bluetooth_on=unknown', r.stdout)
        self.assertIn('bluetooth_on=0', self.run_op('status', SETTING='0').stdout)
