"""Source-only, reproducible Bluetooth candidate packaging."""
import hashlib
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('bt_builder', ROOT / 'tools/build_bt_module.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class BluetoothBuildTest(unittest.TestCase):
    def test_exact_source_permissions_manifest_and_reproducibility(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = ROOT / 'modules/mt6639-bt'
            first, second = root / 'first.zip', root / 'second.zip'
            self.assertEqual(builder.build(source, first), builder.build(source, second))
            with zipfile.ZipFile(first) as z:
                self.assertEqual(set(z.namelist()), set(builder.FILES) | {'SHA256SUMS'})
                for name in builder.FILES:
                    self.assertEqual(z.read(name), (source / name).read_bytes())
                    self.assertEqual((z.getinfo(name).external_attr >> 16) & 0o777,
                                     0o755 if name.endswith('.sh') else 0o644)
                for line in z.read('SHA256SUMS').decode().splitlines():
                    digest, name = line.split('  ')
                    self.assertEqual(hashlib.sha256(z.read(name)).hexdigest(), digest)
            with self.assertRaises(ValueError): builder.build(source, first)

    def test_symlink_and_credentials_never_packaged(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / 'source'
            shutil.copytree(ROOT / 'modules/mt6639-bt', source)
            file = source / 'config.conf'
            file.unlink()
            file.symlink_to(source / 'module.prop')
            with self.assertRaises(ValueError): builder.build(source, root / 'bad.zip')
            file.unlink()
            file.write_text('-----BEGIN PRIVATE KEY-----\n')
            with self.assertRaises(ValueError): builder.build(source, root / 'bad.zip')
            self.assertFalse((root / 'bad.zip').exists())
