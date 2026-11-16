"""Run the console's passphrase installer with only device I/O replaced."""
import unittest

from tests.test_radio_control import HOTSPOT, RadioFixture


def to_hex(text):
    return text.encode('latin-1').hex()


class RadioKeyTests(RadioFixture):
    def setUp(self):
        super().setUp()
        self.private = self.hot_work / 'private'

    def set_key(self, hexline, **kwargs):
        return self.run_op('set', script='radio-key.sh', stdin=hexline, **kwargs)

    def leftovers(self):
        return sorted(p.name for p in self.private.iterdir() if p.name != 'ap.key')

    def test_installs_the_exact_passphrase_privately_and_never_echoes_it(self):
        self.key.unlink()
        self.private.rmdir()
        self.assertEqual(self.run_op('status', script='radio-key.sh').stdout, 'ap_key=0\n')
        secret = 'Pass phrase\'"$`\;|&<>!~ 63'
        r = self.set_key(to_hex(secret) + '\n')
        self.assertEqual((r.returncode, r.stdout, r.stderr), (0, 'ap_key=1\n', ''))
        self.assertEqual(self.key.read_text(), secret + '\n')
        self.assertEqual(oct(self.key.stat().st_mode & 0o777), '0o600')
        self.assertEqual(oct(self.private.stat().st_mode & 0o777), '0o700')
        self.assertEqual(self.leftovers(), [])
        self.assertEqual(self.run_op('status', script='radio-key.sh').stdout, 'ap_key=1\n')
        # The unified controller sees the same file.
        self.assertEqual(self.status()['ap_key'], '1')
        self.assertEqual(self.run_op('start').returncode, 0)

    def test_length_bounds_and_missing_trailing_newline(self):
        for secret in ('12345678', 'x' * 63):
            r = self.set_key(to_hex(secret))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(self.key.read_text(), secret + '\n')

    def test_rejected_input_leaves_the_existing_key_untouched(self):
        cases = [
            ('', 'key_input_missing'),
            ('\n', 'key_encoding_invalid'),
            (to_hex('1234567'), 'key_length_invalid'),
            (to_hex('x' * 64), 'key_length_invalid'),
            (to_hex('12345678') + '4', 'key_length_invalid'),
            (to_hex('12345678').upper().replace('3', 'A') + 'AB', 'key_encoding_invalid'),
            ('zz' * 8, 'key_encoding_invalid'),
            ('31323334 35363738', 'key_encoding_invalid'),
            (to_hex('1234\n5678'), 'key_characters_invalid'),
            (to_hex('1234\t5678'), 'key_characters_invalid'),
            (to_hex('1234\x7f5678'), 'key_characters_invalid'),
            (to_hex('1234\xe45678'), 'key_characters_invalid'),
            ('00' * 8, 'key_characters_invalid'),
            (to_hex('12345678') + "; touch MARKER", 'key_encoding_invalid'),
        ]
        for line, reason in cases:
            with self.subTest(line=line[:24], reason=reason):
                r = self.set_key(line)
                self.assertEqual(r.returncode, 65, r.stdout + r.stderr)
                self.assertEqual(r.stderr, f'REJECT {reason}\n')
                self.assertEqual(r.stdout, '')
                self.assertEqual(self.key.read_text(), 'fixture-password\n')
                self.assertEqual(self.leftovers(), [])
        self.assertFalse(any(self.root.rglob('MARKER')))

    def test_only_the_first_line_is_read(self):
        r = self.set_key(to_hex('first-line-key') + '\n' + to_hex('second-line-key') + '\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.key.read_text(), 'first-line-key\n')

    def test_links_are_never_followed(self):
        target = self.root / 'target-key'
        target.write_text('do-not-touch\n')
        self.key.unlink()
        self.key.symlink_to(target)
        self.assertEqual(self.run_op('status', script='radio-key.sh').stdout, 'ap_key=0\n')
        r = self.set_key(to_hex('replacement-key'))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.key.is_symlink())
        self.assertEqual(self.key.read_text(), 'replacement-key\n')
        self.assertEqual(target.read_text(), 'do-not-touch\n')

        elsewhere = self.root / 'elsewhere'
        elsewhere.mkdir()
        self.key.unlink()
        self.private.rmdir()
        self.private.symlink_to(elsewhere)
        r = self.set_key(to_hex('replacement-key'))
        self.assertEqual(r.returncode, 77)
        self.assertEqual(r.stderr, 'REJECT private_directory_invalid\n')
        self.assertEqual(list(elsewhere.iterdir()), [])

    def test_identity_and_usage(self):
        line = to_hex('replacement-key')
        self.assertEqual(self.set_key(line, env={'TEST_UID': '2000'}).returncode, 77)
        self.assertEqual(self.set_key(line, env={'TEST_CONTEXT': 'u:r:shell:s0'}).returncode, 77)
        self.assertEqual(self.set_key(line, moddir='/tmp/elsewhere').returncode, 64)
        self.assertEqual(self.run_op('set', 'extra', script='radio-key.sh', stdin=line).returncode, 64)
        self.assertEqual(self.run_op('show', script='radio-key.sh').returncode, 64)
        self.assertEqual(self.set_key(line, env={'TEST_OWNER': '2000'}).returncode, 77)
        self.assertEqual(self.key.read_text(), 'fixture-password\n')

    def test_passphrase_never_reaches_an_argument_vector(self):
        source = (HOTSPOT / 'bin/radio-key.sh').read_text()
        # Digits travel only through the builtin echo into awk's standard input.
        self.assertIn('echo "$hex" | LC_ALL=C awk', source)
        for line in source.splitlines():
            if '$hex' in line and not line.lstrip().startswith('#'):
                self.assertNotIn('printf', line, line)
                self.assertNotIn('<<', line, line)
        self.assertNotIn('$key', source.replace('$KEY', ''))


if __name__ == '__main__':
    unittest.main()
