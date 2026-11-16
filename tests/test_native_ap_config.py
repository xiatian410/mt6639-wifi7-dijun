"""File-only profiles and rejection of wrong-band/width success reports."""
from pathlib import Path
import subprocess
import tempfile
import unittest

TOOL = Path(__file__).resolve().parents[1] / 'tools/softap_native_config.sh'


class NativeApConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='mt6639-native-ap-')
        self.addCleanup(self.tmp.cleanup)
        self.task = Path(self.tmp.name)
        (self.task / 'ap.key').write_text('fixture-only-password\n')

    def run_tool(self, op, band='6g', width=20):
        return subprocess.run(['sh', str(TOOL), str(self.task), op, band, str(width)],
                              text=True, capture_output=True)

    def test_supported_profiles_round_trip(self):
        for band, widths in [('2g', [20]), ('5g', [20, 40, 80]),
                             ('6g', [20, 40, 80, 160, 320])]:
            for width in widths:
                with self.subTest(band=band, width=width):
                    result = self.run_tool('render', band, width)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertNotIn('country_code=', result.stdout)
                    (self.task / 'ap.conf').write_text(result.stdout)
                    check = self.run_tool('check', band, width)
                    self.assertEqual(check.returncode, 0, check.stderr)
                    self.assertNotIn('fixture-only-password', check.stdout + check.stderr)

    def test_custom_ssid_is_hex_only_and_checked_exactly(self):
        name = '热点 "\'`;$(false)\\#='
        encoded = name.encode().hex()
        (self.task / 'ap.ssid.hex').write_text(encoded + '\n')
        for band, width in [('2g', 20), ('5g', 80), ('6g', 320)]:
            with self.subTest(band=band, width=width):
                result = self.run_tool('render', band, width)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f'ssid2={encoded}\n', result.stdout)
                self.assertNotIn('ssid=', result.stdout)
                self.assertNotIn(name, result.stdout)
                (self.task / 'ap.conf').write_text(result.stdout)
                self.assertEqual(self.run_tool('check', band, width).returncode, 0)
                for altered in [result.stdout + 'ssid=unexpected\n',
                                result.stdout.replace(encoded, '6162')]:
                    (self.task / 'ap.conf').write_text(altered)
                    self.assertEqual(self.run_tool('check', band, width).returncode, 69)

    def test_custom_ssid_invalid_file_is_not_silently_defaulted(self):
        name = self.task / 'ap.ssid.hex'
        for value in ['', '00', '61\n62\n', 'f4908080', '61' * 33, 'not-hex']:
            name.write_text(value)
            result = self.run_tool('render')
            self.assertIn(result.returncode, (65, 66))
            self.assertEqual(result.stdout, '')
        name.unlink()
        name.symlink_to(self.task / 'missing')
        self.assertEqual(self.run_tool('render').returncode, 66)

    def test_2ghz_profile_is_he_only(self):
        rendered = self.run_tool('render', '2g', 20).stdout
        self.assertIn('hw_mode=g\n', rendered)
        self.assertIn('op_class=81\nchannel=6\n', rendered)
        self.assertIn('ieee80211n=1\n', rendered)
        self.assertIn('ieee80211ax=1\n', rendered)
        for absent in ['ieee80211ac=', 'ieee80211be=',
                       'eht_oper_chwidth=', 'eht_oper_centr_freq_seg0_idx=']:
            self.assertNotIn(absent, rendered)
        self.assertEqual(self.run_tool('render', '2g', 40).returncode, 64)

    def test_6ghz_channelization(self):
        forty = self.run_tool('render', width=40).stdout
        self.assertIn('op_class=132\n', forty)
        self.assertIn('eht_oper_centr_freq_seg0_idx=35\n', forty)
        widest = self.run_tool('render', width=320).stdout
        self.assertIn('op_class=137\n', widest)
        self.assertIn('he_oper_chwidth=2\nhe_oper_centr_freq_seg0_idx=47\n', widest)
        self.assertIn('eht_oper_chwidth=4\neht_oper_centr_freq_seg0_idx=31\n', widest)

    def test_rejects_unsupported_and_config_drift(self):
        self.assertEqual(self.run_tool('render', '5g', 320).returncode, 64)
        self.assertEqual(self.run_tool('render', '5g', 160).returncode, 64)
        config = self.run_tool('render').stdout
        for suffix in ['country_code=US\n', 'channel=37\n', 'include=/some/file\n']:
            (self.task / 'ap.conf').write_text(config + suffix)
            self.assertEqual(self.run_tool('check').returncode, 69)

    def test_rejects_key_injection_without_echo(self):
        (self.task / 'ap.key').write_text('private-secret\nchannel=36\n')
        result = self.run_tool('render')
        self.assertEqual(result.returncode, 65)
        self.assertNotIn('private-secret', result.stdout + result.stderr)

    def test_status_rejects_band_or_width_fallback(self):
        status = ('state=ENABLED\nfreq=5180\nchannel=36\nsecondary_channel=1\n'
                  'hw_mode=a\n'
                  'ieee80211ax=1\nieee80211be=1\neht_oper_chwidth=1\n'
                  'eht_oper_centr_freq_seg0_idx=42\nhe_oper_chwidth=1\n'
                  'he_oper_centr_freq_seg0_idx=42\n')
        (self.task / 'status.active').write_text(status)
        self.assertEqual(self.run_tool('status', '5g', 80).returncode, 0)
        for wrong in [status.replace('freq=5180', 'freq=6135'),
                      status.replace('eht_oper_chwidth=1', 'eht_oper_chwidth=0'),
                      status.replace('hw_mode=a', 'hw_mode=g'),
                      status + 'channel=36\n']:
            (self.task / 'status.active').write_text(wrong)
            self.assertEqual(self.run_tool('status', '5g', 80).returncode, 69)

    def test_6ghz_40_status_rejects_ambiguous_secondary(self):
        status = ('state=ENABLED\nfreq=6135\nchannel=37\nsecondary_channel=-1\n'
                  'hw_mode=a\n'
                  'ieee80211ax=1\nieee80211be=1\neht_oper_chwidth=0\n'
                  'eht_oper_centr_freq_seg0_idx=35\nhe_oper_chwidth=0\n'
                  'he_oper_centr_freq_seg0_idx=35\n')
        (self.task / 'status.active').write_text(status)
        self.assertEqual(self.run_tool('status', '6g', 40).returncode, 0)
        (self.task / 'status.active').write_text(status.replace('secondary_channel=-1', 'secondary_channel=0'))
        self.assertEqual(self.run_tool('status', '6g', 40).returncode, 69)

    def test_2ghz_status_requires_he_and_no_eht(self):
        status = ('state=ENABLED\nfreq=2437\nchannel=6\nsecondary_channel=0\n'
                  'hw_mode=g\nieee80211n=1\nieee80211ax=1\nieee80211be=0\n'
                  'he_oper_chwidth=0\nhe_oper_centr_freq_seg0_idx=6\n')
        (self.task / 'status.active').write_text(status)
        self.assertEqual(self.run_tool('status', '2g', 20).returncode, 0)
        for wrong in [status.replace('ieee80211ax=1\n', ''),
                      status.replace('ieee80211be=0', 'ieee80211be=1'),
                      status.replace('ieee80211n=1\n', ''),
                      status.replace('freq=2437', 'freq=5180')]:
            (self.task / 'status.active').write_text(wrong)
            self.assertEqual(self.run_tool('status', '2g', 20).returncode, 69)


if __name__ == '__main__':
    unittest.main()
