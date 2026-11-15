"""Execute native-hotspot preflight with Android I/O doubled; never start radios."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOTSPOT = ROOT / 'modules/mt6639-hotspot'
SIX = ROOT / 'modules/mt6639-6g'
KERNEL = '6.18.21-android17-5-g284297031c53-abogki553682993-4k'
DRIVER = '1f962c076c38c1a9e24ab7127427a1835d860aed6cb1d051a8e07b068771ac96'


class HotspotStartRequirements(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='hotspot-start-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.mod = self.root / 'module'
        shutil.copytree(HOTSPOT, self.mod)
        self.assets = self.mod / 'bin'
        shutil.copyfile(SIX / 'bin/compat.sh', self.assets / 'compat.sh')
        shutil.copyfile(SIX / 'compatibility.conf', self.assets / 'compatibility.conf')
        self.stub = self.root / 'stub'
        self.stub.mkdir()
        self.env = dict(os.environ, PATH=str(self.stub) + ':' + os.environ['PATH'],
                        TEST_KERNEL=KERNEL, TEST_DRIVER=DRIVER, TEST_DEVICE='dijun', TEST_SDK='37')
        self.status = self.root / 'sta'
        self.env['TEST_STA'] = str(self.status)
        self.status.write_text('Wifi is enabled\nWifi is disconnected\n')
        for name, body in {
            'uname': 'echo "$TEST_KERNEL"',
            'getprop': '''case "$1" in
ro.product.device) echo "$TEST_DEVICE" ;;
ro.build.version.sdk) echo "$TEST_SDK" ;;
ro.build.fingerprint) echo 'OTA-VERSION-NOT-A-GATE' ;;
*) : ;;
esac''',
            'sha256sum': '''[ "${TEST_UNREADABLE:-0}" = 0 ] || exit 1
printf '%s  %s\n' "$TEST_DRIVER" "$1"''',
            'cmd': 'cat "$TEST_STA"',
            'getenforce': 'echo Enforcing',
            'dumpsys': "echo '    Upstream wanted: false'",
        }.items():
            p = self.stub / name
            p.write_text('#!/bin/sh\n' + body + '\n')
            p.chmod(0o755)

    def identity(self):
        return subprocess.run(['sh', str(self.assets / 'hotspot-identity.sh'), str(self.assets)],
                              env=self.env, capture_output=True, text=True, timeout=10)

    def test_reviewed_kernel_driver_tuples_and_ota_independence(self):
        for line in (SIX / 'compatibility.conf').read_text().splitlines():
            if not line or line.startswith('#'):
                continue
            profile, kernel, cfg, *drivers = line.split()
            for driver in drivers:
                with self.subTest(profile=profile, driver=driver):
                    self.env.update(TEST_KERNEL=kernel, TEST_DRIVER=driver)
                    r = self.identity()
                    self.assertEqual(r.returncode, 0, r.stderr)
                    self.assertIn('compatibility_profile=' + profile, r.stdout)

    def test_unknown_mixed_unreadable_and_malformed_identity_rejected(self):
        for change, reason in [({'TEST_KERNEL': 'unknown'}, 'kernel_mismatch'),
            ({'TEST_DRIVER': '0' * 64}, 'driver_mismatch'),
            ({'TEST_DRIVER': '54619c2e9521fc084edd4ec93282715ac10e716ad4ae0a27ec5588fb64e618ea'}, 'driver_mismatch'),
            ({'TEST_UNREADABLE': '1'}, 'driver_unreadable'),
            ({'TEST_DEVICE': 'other'}, 'device_mismatch'),
            ({'TEST_SDK': '36'}, 'sdk_mismatch')]:
            before = self.env.copy()
            with self.subTest(change=change):
                self.env.update(change)
                r = self.identity()
                self.assertEqual(r.returncode, 69, r.stderr)
                self.assertIn(reason, r.stderr)
            self.env = before
        with (self.assets / 'compatibility.conf').open('a') as f:
            f.write('malformed row\n')
        self.assertIn('compatibility_table_invalid', self.identity().stderr)

    def upstream(self, request='auto', band='6g', file=False):
        args = ['sh', str(self.assets / 'hotspot-upstream.sh'), request, band]
        if file:
            args.append(str(self.status))
        return subprocess.run(args, env=self.env, capture_output=True, text=True, timeout=10)

    def test_mode_resolution_live_and_captured_status_agree(self):
        for status, mode in [
            ('Wifi is enabled\nWifi is disconnected\n', 'cell'),
            ('Wifi is enabled\nWifi is connected to "LabNet-6G"\nSupplicant state: COMPLETED\n', 'wifi'),
            ('Wifi is enabled\nWifi is connected to "LabNet-other"\nSupplicant state: COMPLETED\n', 'wifi-any'),
        ]:
            self.status.write_text(status)
            for captured in (False, True):
                with self.subTest(mode=mode, captured=captured):
                    r = self.upstream(file=captured)
                    self.assertEqual(r.returncode, 0, r.stderr)
                    self.assertEqual(r.stdout, mode + '\n')
                    self.assertNotIn('LabNet', r.stdout + r.stderr)

    def test_disabled_incomplete_wrong_explicit_mode_and_query_failure_rejected(self):
        for status, request in [('Wifi is disabled\n', 'auto'),
            ('Wifi is enabled\nWifi is connected to "LabNet-other"\n', 'auto'),
            ('Wifi is enabled\nWifi is disconnected\n', 'wifi-any'),
            ('Wifi is enabled\nWifi is connected to "LabNet-other"\nSupplicant state: COMPLETED\n', 'cell')]:
            self.status.write_text(status)
            self.assertEqual(self.upstream(request).returncode, 69)
        self.status.unlink()
        self.assertEqual(self.upstream().returncode, 69)

    def control_preflight(self):
        src = (HOTSPOT / 'bin/control.sh').read_text()
        start = src.index('start_session() {')
        function = src[start:src.index('\nrun_c02_24g()', start)]
        private = self.root / 'private'
        private.mkdir(exist_ok=True, mode=0o700)
        (private / 'ap.key').write_text('fixture-password\n')
        (private / 'ap.key').chmod(0o600)
        harness = '''set -u
MODDIR=$1; WORK=$2; PRIVATE=$WORK/private
ARG_BAND=; ARG_WIDTH=; TASK_FILE=$WORK/no-session
log() { printf '%s\n' "$*"; }
sha_ok() { return 0; }
android_env_ready() { return 0; }
publish_status() { echo "preflight_passed=$upstream_mode key=$upstream_key"; }
# Stop before mktemp, staging, process creation or any radio action.
boot_id() { return 70; }
'''
        return subprocess.run(['sh', '-c', harness + function + '\nstart_session',
                               'sh', str(self.mod), str(self.root)], env=self.env,
                              capture_output=True, text=True, timeout=15)

    def test_real_controller_requires_only_ap_key_for_cell_and_wifi_any(self):
        for status, mode in [('Wifi is enabled\nWifi is disconnected\n', 'cell'),
            ('Wifi is enabled\nWifi is connected to "LabNet-other"\nSupplicant state: COMPLETED\n', 'wifi-any')]:
            self.status.write_text(status)
            r = self.control_preflight()
            self.assertEqual(r.returncode, 70, r.stdout + r.stderr)
            self.assertIn(f'preflight_passed={mode} key=none', r.stdout)
            self.assertFalse((self.root / 'private/reconnect.key').exists())

    def test_real_controller_still_requires_documented_wifi_recovery_key(self):
        self.status.write_text('Wifi is enabled\nWifi is connected to "LabNet-6G"\nSupplicant state: COMPLETED\n')
        r = self.control_preflight()
        self.assertEqual(r.returncode, 66, r.stdout + r.stderr)
        self.assertIn('private_file_invalid reconnect.key', r.stdout)
        key = self.root / 'private/reconnect.key'
        key.write_text('fixture-password\n')
        key.chmod(0o600)
        r = self.control_preflight()
        self.assertEqual(r.returncode, 70, r.stdout + r.stderr)
        self.assertIn('preflight_passed=wifi key=reconnect.key', r.stdout)

    def test_staging_without_upstream_key_copies_identity_and_cleanup_removes_it(self):
        src = (HOTSPOT / 'bin/control.sh').read_text()
        start = src.index('stage_native_task() {')
        function = src[start:src.index('\nabort_staged_start()', start)]
        for name in ('softap_native_once.sh', 'softap_native_config.sh', 'hostapd',
                     'hostapd_cli', 'delete_ifindex', 'native-tether.dex',
                     'softap-profile.dex', 'twt_recover.sh'):
            (self.assets / name).write_text('fixture\n')
        (self.assets / 'softap_native_config.sh').write_text('#!/bin/sh\nexit 0\n')
        private = self.root / 'private'
        private.mkdir(mode=0o700)
        (private / 'ap.key').write_text('fixture-password\n')
        task = self.root / 'mt6639-native-ap-fixture'
        task.mkdir(mode=0o700)
        harness = 'umask 077; MODDIR=$1; PRIVATE=$2; ' + function + '\nstage_native_task "$3" none'
        r = subprocess.run(['sh', '-c', harness, 'sh', str(self.mod), str(private), str(task)],
                           capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 0, r.stderr)
        for name in ('hotspot-identity.sh', 'hotspot-upstream.sh', 'compat.sh', 'compatibility.conf'):
            self.assertEqual((task / name).read_bytes(), (self.assets / name).read_bytes())
        self.assertFalse((task / 'none').exists())
        start = src.index('discard_staged_task() {')
        cleanup = src[start:src.index('\n}\n', start) + 3]
        cleanup = cleanup.replace('/data/local/tmp/mt6639-native-ap-', str(self.root / 'mt6639-native-ap-'))
        r = subprocess.run(['sh', '-c', 'TASK_FILE=$2; ' + cleanup + '\ndiscard_staged_task "$1"',
                            'sh', str(task), str(self.root / 'no-session')], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(task.exists())

    def test_real_runner_rechecks_identity_and_conditional_key_before_radio(self):
        task = self.root / 'mt6639-native-ap-runner'
        task.mkdir(mode=0o700)
        for name in ('hotspot-identity.sh', 'hotspot-upstream.sh', 'compat.sh', 'compatibility.conf'):
            shutil.copyfile(self.assets / name, task / name)
        marker = self.root / 'config-check-reached'
        hashes = {}
        for name, digest in {
            'hostapd': '15023e3bfe6b08415ebcc92479c0cd4fb14adb57b9010266af73bcc1bdc7bc2b',
            'hostapd_cli': '2da7d467b7b2628c4da40fb5ccc101b17f8b279bd9c038c32e4ae6e5b2924a42',
            'delete_ifindex': 'd20169f8733dc3bd2813806b3deda79e84b497e40e4a0f82bb97cd585844d655',
            'softap-profile.dex': '7ff17f05008e77535dacac13c5c2f216c664bc26403d6cbfe7da7fb9b7c04017',
            'softap_native_config.sh': '7488253f5f93718f196033aed6ed8b6ead27b300fd2b0a07c6318b64cb73dfca',
            'native-tether.dex': '71c2ff994fcc2f2ede23eeb361b9d153d9a72c00240ad90c677deb23827fea56',
        }.items():
            hashes[str(task / name)] = digest
            (task / name).write_text('fixture\n')
        hashes['/apex/com.android.tethering/javalib/framework-tethering.jar'] = '0b6f6c859301dae3276b9375c3b75333168dc5b76292ed9da03e29b59fc887bb'
        # Expected hash responses and the Android ABI/services are explicit
        # doubles. The original runner, profile selection and key logic execute.
        cases = '\n'.join(f'{path}) echo "{digest}  $1" ;;' for path, digest in hashes.items())
        (self.stub / 'sha256sum').write_text('#!/bin/sh\ncase "$1" in\n' + cases +
            '\n*) printf "%s  %s\\n" "$TEST_DRIVER" "$1" ;;\nesac\n')
        (self.stub / 'id').write_text('#!/bin/sh\ncase "$1" in -Z) echo u:r:ksu:s0 ;; *) echo 0 ;; esac\n')
        (self.stub / 'id').chmod(0o755)
        (self.stub / 'app_process').write_text('#!/bin/sh\necho ap_state=11\n')
        (self.stub / 'app_process').chmod(0o755)
        (self.stub / 'dumpsys').write_text("#!/bin/sh\necho '    Upstream wanted: false'\necho '    Current upstream interface(s): null'\n")
        (self.stub / 'ip').write_text("#!/bin/sh\necho '    inet 198.51.100.1/24 scope global rmnet0'\n")
        (self.stub / 'ip').chmod(0o755)
        (task / 'hostapd').write_text('#!/bin/sh\ntouch "' + str(marker) + '"\nexit 92\n')
        (task / 'hostapd').chmod(0o755)
        (task / 'softap_native_config.sh').write_text('#!/bin/sh\nexit 0\n')
        (task / 'ap.key').write_text('fixture-password\n')
        (task / 'ap.conf').write_text('fixture\n')
        forward = self.root / 'ip_forward'
        forward.write_text('0\n')
        src = (ROOT / 'tools/softap_native_once.sh').read_text().replace(
            '/data/local/tmp/mt6639-native-ap-', str(self.root / 'mt6639-native-ap-')).replace(
            '/data/adb/modules/mt6639-hotspot', str(self.root / 'no-installed-module')).replace(
            '/proc/sys/net/ipv4/ip_forward', str(forward)).replace('/sys/class/net/', str(self.root / 'no-net') + '/')
        runner = task / 'softap_native_once.sh'
        runner.write_text(src)
        for status, mode in [
            ('Wifi is enabled\nWifi is disconnected\n', 'cell'),
            ('Wifi is enabled\nWifi is connected to "LabNet-other"\nSupplicant state: COMPLETED\nFrequency: 6135MHz\n', 'wifi-any'),
        ]:
            self.status.write_text(status)
            marker.unlink(missing_ok=True)
            r = subprocess.run(['sh', str(runner), str(task), 'run-tether', '6g', '20'],
                               env=self.env, capture_output=True, text=True, timeout=15)
            self.assertEqual(r.returncode, 69, r.stdout + r.stderr)
            self.assertTrue(marker.exists(), (task / 'failure').read_text() if (task / 'failure').exists() else r.stderr)
            self.assertEqual((task / 'upstream.mode').read_text(), mode + '\n')
            self.assertFalse((task / 'reconnect.key').exists())
        marker.unlink()
        self.env['TEST_DRIVER'] = '0' * 64
        r = subprocess.run(['sh', str(runner), str(task), 'run-tether', '6g', '20'],
                           env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(r.returncode, 69)
        self.assertIn('driver_mismatch', (task / 'identity.check').read_text())
        self.assertFalse(marker.exists())
        self.env['TEST_DRIVER'] = DRIVER
        self.status.write_text('Wifi is enabled\nWifi is connected to "LabNet-6G"\nSupplicant state: COMPLETED\n')
        r = subprocess.run(['sh', str(runner), str(task), 'run-tether', '6g', '20'],
                           env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(r.returncode, 66)
        self.assertIn('missing_upstream_recovery_key', (task / 'failure').read_text())
        self.assertFalse(marker.exists())


if __name__ == '__main__':
    unittest.main()
