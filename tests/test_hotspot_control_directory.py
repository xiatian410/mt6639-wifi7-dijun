"""Execute the real hotspot controller preamble, before any radio operations."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class HotspotControlDirectoryTest(unittest.TestCase):
    def test_directory_checks_precede_logging_and_do_not_follow_symlinks(self):
        original = (REPO / 'modules/mt6639-hotspot/bin/control.sh').read_text()
        prefix = original[:original.index('log() {')]
        for kind in ('missing', 'valid', 'old_writable', 'symlink', 'file', 'foreign_owner', 'chmod_fail'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                module = root / 'module'
                module.mkdir()
                work = root / 'work'
                target = root / 'target'
                target.mkdir(mode=0o755)
                target.chmod(0o755)
                if kind == 'symlink': work.symlink_to(target)
                elif kind == 'file': work.write_text('sentinel')
                elif kind != 'missing':
                    work.mkdir(mode=0o700)
                    if kind == 'old_writable': work.chmod(0o777)
                source = prefix.replace('/data/adb/modules/mt6639-hotspot', str(module)).replace(
                    '/data/adb/mt6639-hotspot', str(work))
                source = source.replace('"$(stat -c %u "$work_parent")" = 0',
                                        f'"$(stat -c %u "$work_parent")" = {os.getuid()}').replace(
                    '"$(stat -c %u "$WORK")" = 0',
                    f'"$(stat -c %u "$WORK")" = {os.getuid()}')
                stubs = '''id() { if [ "$1" = -Z ]; then echo u:r:ksu:s0; else echo 0; fi; }
'''
                if kind == 'foreign_owner':
                    stubs += f'''stat() {{ if [ "$3" = '{work}' ] && [ "$2" = %u ]; then echo 99999; else command stat "$@"; fi; }}\n'''
                if kind == 'chmod_fail': stubs += 'chmod() { return 1; }\n'
                result = subprocess.run(['sh', '-c', stubs + source], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, {'symlink': 77, 'file': 77,
                    'foreign_owner': 77, 'chmod_fail': 74}.get(kind, 0), result.stderr)
                self.assertEqual(target.stat().st_mode & 0o777, 0o755)
                if kind in ('missing', 'valid', 'old_writable'):
                    self.assertEqual(work.stat().st_mode & 0o777, 0o700)
                if kind == 'file': self.assertEqual(work.read_text(), 'sentinel')
                self.assertFalse((work / 'control.log').exists())
