"""File-only SSID preference and real task staging; no phone or radio access."""
import shutil
import subprocess
import unittest

from tests.test_radio_control import HOTSPOT, ROOT, RadioFixture


class RadioNameTests(RadioFixture):
    def setUp(self):
        super().setUp()
        self.private = self.hot_work / 'private'
        self.name = self.private / 'ap.ssid.hex'

    def set_name(self, data, **kwargs):
        return self.run_op('set', script='radio-name.sh', stdin=data, **kwargs)

    def name_status(self, **kwargs):
        return self.run_op('status', script='radio-name.sh', **kwargs)

    def test_default_and_exact_unicode_or_metacharacter_round_trip(self):
        self.assertEqual(self.name_status().stdout, 'ssid_hex=\n')
        self.assertEqual(self.status()['ssid_hex'], '')
        light = self.run_op('status')
        full = self.run_op('status', 'full')
        self.assertEqual(light.returncode, 0, light.stderr)
        self.assertEqual(full.returncode, 0, full.stderr)
        self.assertIn('ssid_status_rc=0\nssid_hex=\n', light.stdout)
        self.assertIn('ssid_status_rc=0\nssid_hex=\n', full.stdout)
        for name in ('a', 'x' * 32, '热点网络', '热点' * 5 + 'AB',
                     'Café 📶', ' "\'`;$(touch MARKER)\\#= '):
            with self.subTest(name=name):
                encoded = name.encode().hex()
                result = self.set_name(encoded + '\n')
                self.assertEqual((result.returncode, result.stdout, result.stderr),
                                 (0, f'ssid_hex={encoded}\n', ''))
                self.assertEqual(self.name.read_text(), encoded + '\n')
                self.assertEqual(self.name.stat().st_mode & 0o777, 0o600)
                self.assertEqual(self.private.stat().st_mode & 0o777, 0o700)
                self.assertEqual(self.name_status().stdout, result.stdout)
                self.assertEqual(self.status()['ssid_hex'], encoded)
                self.assertEqual(self.status()['ssid_status_rc'], '0')
        self.assertFalse(any(self.root.rglob('MARKER')))

    def test_rejects_invalid_utf8_controls_and_transport_without_overwriting(self):
        original = 'saved'.encode().hex() + '\n'
        self.assertEqual(self.set_name(original).returncode, 0)
        invalid = ['', '\n', '6', '6A', 'zz', '61 62', '61\n62\n', '61\n\n',
                   '61\x00', '61\r\n', '61' * 33,
                   '80', 'c0af', 'c1bf', 'c2', 'e08080', 'eda080', 'f0808080',
                   'f4908080', 'f5808080', 'e282', 'e228a1', 'fe', 'ff',
                   *[f'{c:02x}' for c in range(32)], '7f',
                   *[chr(c).encode().hex() for c in range(128, 160)],
                   'e280a8', 'e280a9']
        for value in invalid:
            with self.subTest(value=repr(value)):
                result = self.set_name(value)
                self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
                self.assertEqual(result.stdout, '')
                self.assertEqual(self.name.read_text(), original)
                self.assertEqual(list(self.private.glob('.ap.ssid.hex.*')), [])

    def test_permission_identity_and_symlink_refusals(self):
        for env in ({'TEST_UID': '2000'}, {'TEST_CONTEXT': 'u:r:shell:s0'},
                    {'TEST_OWNER': '2000'}):
            self.assertEqual(self.set_name('61', env=env).returncode, 77)
        self.assertEqual(self.set_name('61', moddir='/tmp/other').returncode, 64)
        self.assertEqual(self.run_op('set', 'extra', script='radio-name.sh', stdin='61').returncode, 64)
        self.assertEqual(self.run_op('unknown', script='radio-name.sh').returncode, 64)
        target = self.root / 'target'
        target.write_text('unchanged\n')
        self.name.symlink_to(target)
        self.assertEqual(self.set_name('61').returncode, 66)
        self.assertEqual(self.name_status().returncode, 66)
        self.assertEqual(target.read_text(), 'unchanged\n')
        self.name.unlink()
        self.assertEqual(self.set_name('61').returncode, 0)
        self.name.chmod(0o644)
        self.assertEqual(self.name_status().returncode, 66)
        self.name.chmod(0o600)
        self.name.write_text('not hex\n')
        self.assertEqual(self.name_status().returncode, 65)
        state = self.status()
        self.assertEqual(state['ssid_status_rc'], '65')
        self.assertNotIn('ssid_hex', state)
        self.name.unlink()
        self.key.unlink()
        self.private.rmdir()
        self.private.symlink_to(self.root)
        self.assertEqual(self.set_name('61').returncode, 77)
        self.assertEqual(self.name_status().returncode, 77)
        self.assertFalse((self.root / 'ap.ssid.hex').exists())

    def test_creates_missing_private_directory_and_accepts_no_final_lf(self):
        self.key.unlink()
        self.private.rmdir()
        self.assertEqual(self.name_status().stdout, 'ssid_hex=\n')
        result = self.set_name('e783ade782b9')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.name.read_text(), 'e783ade782b9\n')
        self.assertEqual(self.private.stat().st_mode & 0o777, 0o700)

    def stage(self, task):
        task.mkdir(mode=0o700)
        source = (HOTSPOT / 'bin/control.sh').read_text()
        function = source[source.index('stage_native_task() {'):source.index('\nabort_staged_start()')]
        harness = ('umask 077; MODDIR=$1; PRIVATE=$2; band=6g; width=80; ' + function +
                   '\nstage_native_task "$3" none')
        return subprocess.run(['sh', '-c', harness, 'sh', str(self.mod), str(self.private), str(task)],
                              env=self.env, capture_output=True, text=True, timeout=10)

    def stage_assets(self):
        for name in ('softap_native_once.sh', 'hostapd', 'hostapd_cli', 'delete_ifindex',
                     'native-tether.dex', 'softap-profile.dex', 'twt_recover.sh'):
            (self.mod / 'bin' / name).write_text('fixture\n')
        shutil.copyfile(ROOT / 'tools/softap_native_config.sh', self.mod / 'bin/softap_native_config.sh')

    def test_real_staging_captures_name_once_and_preserves_default(self):
        self.stage_assets()
        task = self.root / 'default-task'
        result = self.stage(task)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ssid=MT6639-Native-6g-80\n', (task / 'ap.conf').read_text())
        self.assertFalse((task / 'ap.ssid.hex').exists())
        first = '测试 $(false)'.encode().hex()
        self.assertEqual(self.set_name(first).returncode, 0)
        custom = self.root / 'custom-task'
        result = self.stage(custom)
        self.assertEqual(result.returncode, 0, result.stderr)
        conf = (custom / 'ap.conf').read_text()
        self.assertIn(f'ssid2={first}\n', conf)
        self.assertNotIn('ssid=', conf)
        self.assertEqual((custom / 'ap.ssid.hex').stat().st_mode & 0o777, 0o600)
        # Even if called outside the UI while running, set only changes the
        # preference. It never restarts the AP or mutates a captured task.
        (self.fix / 'hot.state').write_text('active\n')
        self.assertEqual(self.set_name('next'.encode().hex()).returncode, 0)
        self.assertEqual((custom / 'ap.ssid.hex').read_text(), first + '\n')
        self.assertEqual((custom / 'ap.conf').read_text(), conf)
        self.assertEqual(self.calls(), [])
        next_task = self.root / 'next-task'
        self.assertEqual(self.stage(next_task).returncode, 0)
        self.assertIn('ssid2=6e657874\n', (next_task / 'ap.conf').read_text())

    def test_staging_rejects_corrupt_or_unsafe_name_before_render(self):
        self.stage_assets()
        self.assertEqual(self.set_name('61').returncode, 0)
        for value, mode in [('00', 0o600), ('61', 0o644), ('x' * 66, 0o600)]:
            with self.subTest(value=value, mode=mode):
                self.name.write_text(value)
                self.name.chmod(mode)
                task = self.root / f'task-{mode}-{len(value)}-{value[:2]}'
                result = self.stage(task)
                self.assertEqual(result.returncode, 65, result.stderr)
                self.assertEqual((task / '.stage-error').read_text(), 'name_stage_failed\n')
                self.assertFalse((task / 'ap.conf').exists())


if __name__ == '__main__':
    unittest.main()
