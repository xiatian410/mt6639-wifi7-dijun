#!/usr/bin/env python3
"""Package only maintained Bluetooth module sources; never installs anything."""
import argparse
import hashlib
from pathlib import Path
import re
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
FILES = ('README.md', 'action.sh', 'bin/compat.sh', 'bin/control.sh',
         'config.conf', 'module.prop', 'service.sh', 'skip_mount', 'uninstall.sh')


def build(source, output):
    if output.exists():
        raise ValueError('output already exists')
    if source.is_symlink():
        raise ValueError('module source is a symlink')
    entries = {}
    for name in FILES:
        file = source / name
        if file.is_symlink() or any(p.is_symlink() for p in file.parents if p != source.parent):
            raise ValueError('symlink in source path: ' + name)
        data = file.read_bytes()
        if re.search(rb'BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY|(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}', data):
            raise ValueError('credential pattern in source: ' + name)
        entries[name] = data
    entries['SHA256SUMS'] = ''.join(
        hashlib.sha256(data).hexdigest() + '  ' + name + '\n'
        for name, data in sorted(entries.items())).encode()
    output.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive final creation prevents accidental replacement of older assets.
    with tempfile.TemporaryFile(dir=output.parent) as temporary:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for name, data in sorted(entries.items()):
                entry = zipfile.ZipInfo(name, (2026, 11, 15, 0, 0, 0))
                entry.create_system = 3
                entry.external_attr = ((0o100755 if name.endswith('.sh') else 0o100644) << 16)
                entry.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(entry, data)
        temporary.seek(0)
        with output.open('xb') as target:
            while block := temporary.read(1024 * 1024):
                target.write(block)
    return hashlib.sha256(output.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    print(build(ROOT / 'modules/mt6639-bt', args.output) + '  ' + str(args.output))


if __name__ == '__main__':
    main()
