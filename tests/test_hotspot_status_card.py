"""Execute the hotspot renderer, publisher and controller with Android I/O doubled."""
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / 'modules/mt6639-hotspot'
BOOT = '11111111-1111-4111-8111-111111111111'


class HotspotStatusCardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='hotspot-card-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.mod = self.root / 'module'
        shutil.copytree(MODULE, self.mod)
        self.work = self.root / 'work'
        self.work.mkdir(mode=0o700)
        self.misc = self.root / 'misc'
        self.misc.mkdir()
        self.status = self.misc / 'mt6639-hotspot/status'
        self.status.parent.mkdir()
        self.boot = self.root / 'boot'
        self.boot.write_text(BOOT + '\n')
        for path in self.mod.rglob('*.sh'):
            path.write_text(path.read_text().replace('/data/adb/modules/mt6639-hotspot', str(self.mod)).replace(
                '/data/adb/mt6639-hotspot', str(self.work)).replace('/data/misc', str(self.misc)).replace(
                '/proc/sys/kernel/random/boot_id', str(self.boot)))
        # No host Android runtime is sourced. Android platform services below
        # are explicit doubles; state/presentation code itself is production.
        (self.mod / 'bin/android-env.sh').write_text('android_env_ready() { return 0; }\n')
        shutil.copyfile(self.mod / 'module.prop', self.mod / 'module.prop.template')
        self.stub = self.root / 'stub'
        self.stub.mkdir()
        for name, text in {
            'id': '#!/bin/sh\nif [ "$1" = -Z ]; then echo u:r:ksu:s0; else echo 0; fi\n',
            'stat': '''#!/bin/sh
if [ "$2" = %u ]; then echo 0; else exec REAL_STAT "$@"; fi
'''.replace('REAL_STAT', shutil.which('stat')),
            'getenforce': '#!/bin/sh\necho Enforcing\n',
            'restorecon': '#!/bin/sh\nexit 0\n',
        }.items():
            p = self.stub / name
            p.write_text(text)
            p.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.stub) + ':' + os.environ['PATH'])
        self.snapshot()
        self.sums()

    def sums(self):
        entries = []
        for p in sorted(self.mod.rglob('*')):
            if p.is_file() and p.name not in ('module.prop', 'SHA256SUMS', 'config.conf'):
                entries.append(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + str(p.relative_to(self.mod)) + '\n')
        (self.mod / 'SHA256SUMS').write_text(''.join(entries))

    def snapshot(self, **fields):
        values = dict(schema='mt6639-hotspot-status-v3', state='idle', band='none',
                      width='none', boot=BOOT, ap_key='1', reconnect_6g='1',
                      reconnect_2g='0', enforcing='1', fiveg_upstream='0')
        values.update(fields)
        self.status.write_text(''.join(f'{k}={v}\n' for k, v in values.items()))

    def card(self, mode='update', *args):
        return subprocess.run(['sh', str(self.mod / 'bin/status-card.sh'), str(self.mod), mode, *args],
                              env=self.env, capture_output=True, text=True, timeout=25)

    def description(self):
        return next(line for line in (self.mod / 'module.prop').read_text().splitlines()
                    if line.startswith('description='))

    def verify(self):
        return subprocess.run(['sh', str(self.mod / 'bin/verify-module.sh'), str(self.mod)],
                              capture_output=True, text=True, timeout=5).returncode

    def test_states_bands_and_widths_are_dynamic(self):
        for state, label, band, width in [('idle', '待启动', 'none', 'none'),
             ('starting', '启动中', '5g', '80'), ('active', '热点运行', '6g', '320'),
             ('stopping', '停止中', '2g', '20'), ('unresolved', '需检查或恢复', '6g', '20')]:
            with self.subTest(state=state):
                self.snapshot(state=state, band=band, width=width)
                r = self.card()
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertIn('[' + label + ']', self.description())
                self.assertIn('配置带宽：' + ('未设置' if width == 'none' else width + 'MHz'), self.description())
                self.assertIn('状态检查不代表客户端联网', self.description())
                self.assertEqual(self.verify(), 0)

    def test_metadata_and_asset_tampering_still_rejected(self):
        self.assertEqual(self.card().returncode, 0)
        self.assertEqual(self.verify(), 0)
        p = self.mod / 'module.prop'
        p.write_text(p.read_text().replace('versionCode=35', 'versionCode=99'))
        self.assertNotEqual(self.verify(), 0)
        shutil.copyfile(self.mod / 'module.prop.template', p)
        p = self.mod / 'bin/status-card.sh'
        p.write_text(p.read_text() + '\n# tampered\n')
        self.assertNotEqual(self.verify(), 0)

    def test_failed_operation_survives_busy_presentation_lock(self):
        with (self.work / 'status-card.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.card('update', 'start', '69').returncode, 0)
        self.assertEqual(self.card().returncode, 0)
        self.assertIn('最近操作：启动失败(rc=69)', self.description())
        self.assertEqual(self.card('update', 'recover', '0').returncode, 0)
        self.assertIn('恢复：成功', self.description())

    def test_failed_recovery_is_not_claimed_as_success(self):
        self.assertEqual(self.card('update', 'recover', '73').returncode, 0)
        self.assertIn('恢复：失败(rc=73)', self.description())

    def test_stale_or_previous_boot_snapshot_not_active(self):
        self.snapshot(state='active', band='6g', width='20')
        os.utime(self.status, (time.time() - 100, time.time() - 100))
        self.assertEqual(self.card().returncode, 0)
        self.assertIn('[状态快照过期]', self.description())
        self.snapshot(state='active', boot='22222222-2222-4222-8222-222222222222')
        self.assertEqual(self.card().returncode, 0)
        self.assertIn('[等待本次启动状态]', self.description())

    def test_malformed_or_sensitive_snapshot_not_interpolated(self):
        for extra in ['state=active\n', 'ssid=PRIVATE-SSID\n', 'width=$(touch MARKER)\n']:
            self.snapshot()
            with self.status.open('a') as f: f.write(extra)
            self.assertEqual(self.card().returncode, 0)
            self.assertIn('[状态不可用]', self.description())
            self.assertNotIn('PRIVATE-SSID', self.description())
            self.assertNotIn('$(touch', self.description())
        self.assertFalse((self.mod / 'MARKER').exists())

    def test_missing_snapshot_disabled_remove_and_private_paths(self):
        self.status.unlink()
        self.assertEqual(self.card().returncode, 0)
        self.assertIn('[状态不可用]', self.description())
        (self.mod / 'disable').touch()
        self.assertEqual(self.card().returncode, 0)
        self.assertIn('[模块已禁用]', self.description())
        (self.mod / 'remove').touch()
        self.assertEqual(self.card().returncode, 0)
        self.assertIn('[模块待移除]', self.description())
        self.assertNotIn(str(self.root), self.description())
        self.assertNotIn(BOOT, self.description())

    def test_poll_uses_original_status_chain_and_respects_action_lock(self):
        with (self.work / 'action.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(self.card('poll').returncode, 0)
            self.assertFalse((self.work / 'card-check').exists())
        self.assertEqual(self.card('poll').returncode, 0)
        self.assertEqual((self.work / 'card-check').read_text(), BOOT + '\n0\n')
        self.assertIn('[待启动]', self.description())
        self.assertIn('schema=mt6639-hotspot-status-v3', self.status.read_text())

    def test_poll_command_failure_visible_and_next_poll_recovers(self):
        p = self.mod / 'bin/control.sh'
        source = p.read_text()
        p.write_text('#!/bin/sh\nexit 70\n')
        self.assertEqual(self.card('poll').returncode, 0)
        self.assertIn('[状态检查失败]', self.description())
        p.write_text(source)
        self.assertEqual(self.card('poll').returncode, 0)
        self.assertIn('[待启动]', self.description())

    def test_publisher_updates_card_without_changing_snapshot_schema(self):
        r = subprocess.run(['sh', str(self.mod / 'bin/status_snapshot.sh'), str(self.mod),
                            'publish', 'starting', '6g', '80'], env=self.env,
                           capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('[启动中]', self.description())
        self.assertIn('频段：6GHz', self.description())
        self.assertEqual(len(self.status.read_text().splitlines()), 10)
        self.assertEqual(self.verify(), 0)

    def test_controller_failure_rc_preserved_with_renderer_failure(self):
        # The real controller rejects no-key startup before radio operations.
        # Failing presentation must not change that result or recovery logic.
        r = subprocess.run(['sh', str(self.mod / 'bin/control.sh'), str(self.mod), 'start'],
                           env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, 66, r.stdout + r.stderr)
        expected = r.returncode
        self.assertIn(f'最近操作：启动失败(rc={expected})', self.description())
        (self.mod / 'bin/status-card.sh').write_text('#!/bin/sh\nexit 99\n')
        self.sums()
        r = subprocess.run(['sh', str(self.mod / 'bin/control.sh'), str(self.mod), 'start'],
                           env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(r.returncode, expected, r.stderr)

    def test_symlinks_rejected_and_show_does_not_publish(self):
        before = (self.mod / 'module.prop').read_bytes()
        r = self.card('show')
        self.assertEqual(r.returncode, 0)
        self.assertIn('[待启动]', r.stdout)
        self.assertEqual((self.mod / 'module.prop').read_bytes(), before)
        file = self.mod / 'module.prop'
        file.unlink()
        target = self.root / 'untouched'
        target.write_text('sentinel')
        file.symlink_to(target)
        self.assertNotEqual(self.card().returncode, 0)
        self.assertEqual(target.read_text(), 'sentinel')


    def test_existing_worker_polls_without_another_daemon(self):
        source = (MODULE / 'bin/request_worker.sh').read_text()
        start = source.index('run_loop() {')
        function = source[start:source.index('\nworker_lock()', start)]
        observer = self.mod / 'bin/status-card.sh'
        calls = self.root / 'polls'
        observer.write_text('#!/bin/sh\nprintf "%s\\n" "$2" >> "' + str(calls) + '"\n')
        harness = 'MODDIR="' + str(self.mod) + '"\n' + function + '''
process_one() { return 1; }
ticks=0
sleep() { ticks=$((ticks+1)); [ "$ticks" -lt 31 ] || exit 0; }
run_loop
'''
        result = subprocess.run(['sh', '-c', harness], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.read_text().splitlines(), ['poll', 'poll'])


    def test_worker_publishes_disabled_before_exit(self):
        source = (MODULE / 'bin/request_worker.sh').read_text()
        start = source.index('run_loop() {')
        function = source[start:source.index('\nworker_lock()', start)]
        (self.mod / 'disable').touch()
        result = subprocess.run(['sh', '-c', 'MODDIR="' + str(self.mod) + '"\n' + function + '\nrun_loop\n'],
                                env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('[模块已禁用]', self.description())


    def test_atomic_publication_does_not_mix_fields_during_render(self):
        self.snapshot(state='active', band='6g', width='20')
        newer = self.root / 'newer'
        newer.write_text(self.status.read_text().replace('state=active', 'state=idle').replace(
            'band=6g', 'band=5g').replace('width=20', 'width=80'))
        stub = self.stub / 'cat'
        stub.write_text('#!/bin/sh\n' + shutil.which('cat') + ' "$@"\n' +
                        'if [ "$1" = "' + str(self.status) + '" ]; then cp "' + str(newer) + '" "$1"; fi\n')
        stub.chmod(0o755)
        r = self.card()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('[热点运行]', self.description())
        self.assertIn('频段：6GHz', self.description())
        self.assertIn('配置带宽：20MHz', self.description())
        self.assertIn('state=idle', self.status.read_text())
