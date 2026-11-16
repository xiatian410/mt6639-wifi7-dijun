"""Run the unified radio controller with only device I/O replaced.

`RadioControlTests` drives the real controller against small doubles of the two
module controllers, so every ordering, refusal and ownership decision is
observable as a call list. `RadioContractTests` then runs the real hotspot and
6GHz status entry points, so the fields the controller reads are the fields
those scripts really print. Nothing here starts a radio.
"""
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOTSPOT = ROOT / 'modules/mt6639-hotspot'
SIX = ROOT / 'modules/mt6639-6g'
BOOT = '11111111-1111-4111-8111-111111111111'
OTHER_BOOT = '22222222-2222-4222-8222-222222222222'
DRIVER = '1f962c076c38c1a9e24ab7127427a1835d860aed6cb1d051a8e07b068771ac96'
KERNEL = '6.18.21-android17-5-g284297031c53-abogki553682993-4k'
STA_IDLE = 'Wifi is enabled\nWifi is disconnected\n'
STA_5G = ('Wifi is enabled\nWifi is connected to "Home-5G"\nSupplicant state: COMPLETED\n'
          'BSSID: 02:00:00:00:00:01, Frequency: 5180MHz\n')
STA_6G = ('Wifi is enabled\nWifi is connected to "Home-6G"\nSupplicant state: COMPLETED\n'
          'BSSID: 02:00:00:00:00:02, Frequency: 6135MHz\n')
CELL = '    inet 10.96.1.5/29 scope global rmnet_data2\n'

SIX_DOUBLE = r'''#!/bin/sh
# Double of modules/mt6639-6g/bin/control.sh. A detached guardian keeps every
# descriptor it inherits, so the controller's lock must never reach this file.
F=@FIX@
if [ -e /dev/fd/8 ]; then echo inherited-radio-lock >&2; exit 44; fi
op=${2:-}
[ "$op" = status ] || printf 'six %s\n' "$op" >> "$F/calls"
value() { cat "$F/$1" 2>/dev/null || printf '%s\n' "$2"; }
case "$op" in
status)
    echo "boot=@BOOT@"
    echo 'compatibility_profile=fixture-profile'
    echo 'compatibility_error=none'
    echo 'enabled_config=1'
    echo "state=$(value six.state none)"
    tx=$(value six.tx none)
    echo "active_tx=$tx"
    case "$tx" in none|invalid) ;; *)
        echo 'guardian_pid=4242'
        echo "guardian=$(value six.guardian alive)"
        echo '{"event":"published","detail":"state=not-a-field"}' ;;
    esac
    exit "$(value six.status_rc 0)" ;;
enable)
    echo '启用 6GHz 事务（默认持续模式）；操作按钮可恢复。'
    rc=$(value six.enable_rc 0)
    if [ "$rc" = 0 ]; then
        n=$(($(value six.seq 0) + 1))
        echo "$n" > "$F/six.seq"
        echo "$(value six.enable_state active)" > "$F/six.state"
        echo "@ADB@/mt6639-6g/transactions/t-fixture-$n" > "$F/six.tx"
        echo alive > "$F/six.guardian"
        [ ! -e "$F/wifi.after_enable" ] || cp "$F/wifi.after_enable" "$F/wifi"
        /bin/sleep 30 </dev/null >/dev/null 2>&1 &
        echo "$!" >> "$F/pids"
    else
        cat "$F/six.enable_out" 2>/dev/null
    fi
    exit "$rc" ;;
disable)
    rc=$(value six.disable_rc 0)
    if [ "$rc" = 0 ]; then
        echo restored > "$F/six.state"
        echo none > "$F/six.tx"
        echo '{"status":"restored"}'
    else
        cat "$F/six.disable_out" 2>/dev/null
    fi
    exit "$rc" ;;
refresh)
    rc=$(value six.refresh_rc 0)
    [ "$rc" = 0 ] || cat "$F/six.refresh_out" 2>/dev/null
    exit "$rc" ;;
*) exit 64 ;;
esac
'''

HOTSPOT_DOUBLE = r'''#!/bin/sh
# Double of modules/mt6639-hotspot/bin/control.sh.
F=@FIX@
if [ -e /dev/fd/8 ]; then echo inherited-radio-lock >&2; exit 44; fi
if [ -e /dev/fd/7 ]; then echo inherited-action-lock >&2; exit 45; fi
op=${2:-}
printf 'hotspot %s%s%s\n' "$op" "${3:+ $3}" "${4:+ $4}" >> "$F/calls"
value() { cat "$F/$1" 2>/dev/null || printf '%s\n' "$2"; }
snapshot() {
    mkdir -p "@MISC@/mt6639-hotspot"
    printf 'schema=mt6639-hotspot-status-v3\nstate=%s\nband=%s\nwidth=%s\nboot=%s\nap_key=1\nreconnect_6g=0\nreconnect_2g=0\nenforcing=1\nfiveg_upstream=0\n' \
        "$1" "$2" "$3" "@BOOT@" > "@MISC@/mt6639-hotspot/status"
}
case "$op" in
status)
    rc=$(value hot.status_rc 0)
    [ "$rc" = 0 ] || exit "$rc"
    state=$(value hot.state idle)
    echo "boot=@BOOT@"
    echo 'module=enabled'
    echo "state=$state"
    if [ "$state" = idle ]; then
        echo 'task=none'
        snapshot idle none none
    else
        echo 'task=/data/local/tmp/mt6639-native-ap-fixture'
        echo 'same_boot=1'
        echo 'runner=alive'
        echo 'guardian=alive'
        echo 'action_rc=pending'
        echo 'recovery_rc=pending'
        if [ "$state" = active ]; then
            # hostapd repeats the key "state"; the controller's line comes first.
            echo 'state=ENABLED'
            echo 'freq=6135'
            echo 'channel=37'
            echo 'ieee80211be=1'
        fi
        snapshot "$state" "$(value hot.band 6g)" "$(value hot.width 20)"
    fi ;;
start)
    rc=$(value hot.start_rc 0)
    if [ "$rc" = 0 ]; then
        echo "$(value hot.start_state active)" > "$F/hot.state"
        echo "$3" > "$F/hot.band"
        echo "$4" > "$F/hot.width"
        echo "state=active task=fixture pid=1 band=$3 width=$4 hold=86400"
        /bin/sleep 30 </dev/null >/dev/null 2>&1 &
        echo "$!" >> "$F/pids"
    else
        cat "$F/hot.start_out" 2>/dev/null
    fi
    exit "$rc" ;;
stop)
    rc=$(value hot.stop_rc 0)
    if [ "$rc" = 0 ]; then
        echo idle > "$F/hot.state"
        echo 'state=idle restored=1 action_rc=0'
    else
        cat "$F/hot.stop_out" 2>/dev/null
    fi
    exit "$rc" ;;
toggle) echo 'legacy-toggle' ;;
*) exit 64 ;;
esac
'''

STUBS = {
    'id': '#!/bin/sh\nif [ "${1:-}" = -Z ]; then echo "${TEST_CONTEXT:-u:r:ksu:s0}"; '
          'else echo "${TEST_UID:-0}"; fi\n',
    'stat': '#!/bin/sh\nif [ "$2" = %u ]; then echo "${TEST_OWNER:-0}"; else exec REAL_STAT "$@"; fi\n',
    'getenforce': '#!/bin/sh\necho "${TEST_ENFORCE:-Enforcing}"\n',
    'restorecon': '#!/bin/sh\nexit 0\n',
    'sleep': '#!/bin/sh\nexit 0\n',
    'cmd': '#!/bin/sh\n[ "$1 $2" = "wifi status" ] || exit 64\nexec cat "$TEST_FIX/wifi"\n',
    'ip': '#!/bin/sh\nexec cat "$TEST_FIX/ipaddr"\n',
    'dumpsys': '#!/bin/sh\necho "    Upstream wanted: ${TEST_TETHER_WANTED:-false}"\n',
    'getprop': '''#!/bin/sh
case "$1" in
ro.product.device) echo "${TEST_DEVICE:-dijun}" ;;
ro.build.version.sdk) echo 37 ;;
esac
''',
    'uname': '#!/bin/sh\necho "$TEST_KERNEL"\n',
    # Only the vendor driver is doubled; every other digest is the real one.
    'sha256sum': '''#!/bin/sh
case "${1:-}" in
/vendor/*|/vendor_dlkm/*) printf '%s  %s\\n' "$TEST_DRIVER" "$1" ;;
*) exec REAL_SHA "$@" ;;
esac
''',
}


class RadioFixture(unittest.TestCase):
    real_hotspot = False

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='radio-control-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.adb = self.root / 'adb'
        self.mod = self.adb / 'modules/mt6639-hotspot'
        self.sixmod = self.adb / 'modules/mt6639-6g'
        self.work = self.adb / 'mt6639-radio'
        self.hot_work = self.adb / 'mt6639-hotspot'
        self.misc = self.root / 'misc'
        self.fix = self.root / 'fix'
        self.bootfile = self.root / 'boot'
        self.stub = self.root / 'stub'
        for d in (self.adb / 'modules', self.misc, self.fix, self.stub):
            d.mkdir(parents=True)
        self.bootfile.write_text(BOOT + '\n')
        shutil.copytree(HOTSPOT, self.mod)
        # The build copies the reviewed compatibility table next to the scripts.
        shutil.copyfile(SIX / 'bin/compat.sh', self.mod / 'bin/compat.sh')
        shutil.copyfile(SIX / 'compatibility.conf', self.mod / 'bin/compatibility.conf')
        (self.mod / 'bin/android-env.sh').write_text('android_env_ready() { return 0; }\n')
        if not self.real_hotspot:
            (self.mod / 'bin/control.sh').write_text(self.fill(HOTSPOT_DOUBLE))
        for path in self.mod.rglob('*.sh'):
            path.write_text(self.fill(path.read_text()))
        shutil.copyfile(self.mod / 'module.prop', self.mod / 'module.prop.template')
        self.sums()

        (self.sixmod / 'bin').mkdir(parents=True)
        (self.sixmod / 'bin/control.sh').write_text(self.fill(SIX_DOUBLE))
        (self.sixmod / 'module.prop').write_text(
            'id=mt6639-6g\nversion=v9.9.9-fixture\ndescription=[事务运行] 6GHz：60个已注册信道\n')

        self.hot_work.mkdir(mode=0o700)
        private = self.hot_work / 'private'
        private.mkdir(mode=0o700)
        self.key = private / 'ap.key'
        self.key.write_text('fixture-password\n')
        self.key.chmod(0o600)
        (self.fix / 'wifi').write_text(STA_IDLE)
        (self.fix / 'ipaddr').write_text(CELL)

        for name, body in STUBS.items():
            p = self.stub / name
            p.write_text(body.replace('REAL_STAT', shutil.which('stat'))
                         .replace('REAL_SHA', shutil.which('sha256sum')))
            p.chmod(0o755)
        # Optional: run every script under another shell or awk, for example
        # the mksh that Android ships (MT6639_TEST_SH=/path/to/mksh).
        for tool in ('sh', 'awk'):
            override = os.environ.get('MT6639_TEST_' + tool.upper())
            if override:
                p = self.stub / tool
                p.write_text('#!/bin/sh\nexec ' + override + ' "$@"\n')
                p.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.stub) + ':' + os.environ['PATH'],
                        TEST_FIX=str(self.fix), TEST_KERNEL=KERNEL, TEST_DRIVER=DRIVER)
        self.addCleanup(self.reap)

    def fill(self, text):
        return (text.replace('@FIX@', str(self.fix)).replace('@BOOT@', BOOT)
                .replace('@ADB@', str(self.adb)).replace('@MISC@', str(self.misc))
                .replace('/data/adb', str(self.adb)).replace('/data/misc', str(self.misc))
                .replace('/proc/sys/kernel/random/boot_id', str(self.bootfile))
                .replace('/sys/class/net/mtap0', str(self.root / 'net/mtap0')))

    def sums(self):
        entries = []
        for p in sorted(self.mod.rglob('*')):
            if p.is_file() and p.name not in ('module.prop', 'SHA256SUMS', 'config.conf'):
                entries.append(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' +
                               str(p.relative_to(self.mod)) + '\n')
        (self.mod / 'SHA256SUMS').write_text(''.join(entries))

    def reap(self):
        pids = self.fix / 'pids'
        if pids.exists():
            for pid in pids.read_text().split():
                try:
                    os.kill(int(pid), signal.SIGKILL)
                except (OSError, ValueError):
                    pass

    def run_op(self, *args, env=None, script='radio-control.sh', stdin=None, moddir=None):
        return subprocess.run(
            ['sh', str(self.mod / 'bin' / script), str(moddir or self.mod), *args],
            env=dict(self.env, **(env or {})), capture_output=True, text=True,
            timeout=60, input=stdin)

    def status(self, *args):
        r = self.run_op('status', *args)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        fields = {}
        for line in r.stdout.splitlines():
            key, sep, value = line.partition('=')
            if sep:
                fields.setdefault(key, value)
        self.assertEqual(fields.get('end'), '1', r.stdout)
        return fields

    def calls(self):
        f = self.fix / 'calls'
        return [c for c in f.read_text().splitlines() if c != 'hotspot status'] if f.exists() else []

    def result(self, r):
        lines = [line for line in r.stdout.splitlines() if line.startswith('result=')]
        self.assertEqual(len(lines), 1, r.stdout + r.stderr)
        return dict(item.split('=', 1) for item in lines[0].split())

    def phases(self, r):
        return [line[6:] for line in r.stdout.splitlines() if line.startswith('phase=')]

    def set_six(self, state='active', tx='t-fixture-0', guardian='alive'):
        (self.fix / 'six.state').write_text(state + '\n')
        (self.fix / 'six.guardian').write_text(guardian + '\n')
        path = tx if tx in ('none', 'invalid') else f'{self.adb}/mt6639-6g/transactions/{tx}'
        (self.fix / 'six.tx').write_text(path + '\n')

    def set_hotspot(self, state, band='6g', width='20'):
        (self.fix / 'hot.state').write_text(state + '\n')
        (self.fix / 'hot.band').write_text(band + '\n')
        (self.fix / 'hot.width').write_text(width + '\n')

    def record(self):
        path = self.work / 'session'
        if not path.is_file() or path.is_symlink():
            return None
        return dict(line.split('=', 1) for line in path.read_text().splitlines())

    def lock_free(self):
        with (self.work / 'control.lock').open('w') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return False
            return True


class RadioControlTests(RadioFixture):
    def test_status_reports_both_layers_and_changes_nothing(self):
        s = self.status()
        self.assertEqual(s['schema'], 'mt6639-radio-status-v1')
        self.assertEqual((s['mode'], s['busy'], s['boot']), ('light', '0', BOOT))
        self.assertEqual((s['six_module'], s['six_tx'], s['six_ready']), ('present', 'none', '0'))
        self.assertEqual(s['six_version'], 'v9.9.9-fixture')
        self.assertEqual(s['six_card'], '[事务运行] 6GHz：60个已注册信道')
        # No snapshot was ever published, and a light status never asks for one.
        self.assertEqual((s['hotspot_state'], s['hotspot_checked'], s['hotspot_snapshot']),
                         ('unknown', '0', '0'))
        self.assertEqual((s['wifi'], s['sta'], s['sta_freq']), ('1', 'disconnected', 'none'))
        self.assertEqual((s['upstream'], s['upstream_ok'], s['cell_data']), ('cell', '1', '1'))
        self.assertEqual((s['enforcing'], s['ap_key'], s['pref_width']), ('1', '1', '20'))
        self.assertNotIn('integrity', s)
        self.assertFalse((self.fix / 'calls').exists())

        full = self.status('full')
        self.assertEqual((full['mode'], full['hotspot_checked'], full['hotspot_state']),
                         ('full', '1', 'idle'))
        self.assertEqual((full['integrity'], full['identity'], full['identity_reason']),
                         ('1', '1', 'none'))
        self.assertEqual((full['hotspot_band'], full['hotspot_width']), ('none', 'none'))
        self.assertEqual(self.calls(), [])
        self.assertTrue(self.lock_free())

    def test_status_never_prints_network_identity_or_the_key(self):
        (self.fix / 'wifi').write_text(STA_6G)
        for mode in ((), ('full',)):
            r = self.run_op('status', *mode)
            for secret in ('Home-6G', '02:00:00', 'fixture-password'):
                self.assertNotIn(secret, r.stdout + r.stderr)
        s = self.status()
        self.assertEqual((s['sta'], s['sta_freq'], s['upstream'], s['upstream_ok']),
                         ('connected', '6135', 'wifi-any', '1'))

    def test_one_tap_enables_6ghz_starts_the_hotspot_and_stop_returns_both(self):
        r = self.run_op('start', '80')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.calls(), ['six enable', 'hotspot start 6g 80'])
        self.assertEqual(self.phases(r),
                         ['preflight', 'six_enable', 'sta_settle', 'hotspot_start', 'verify'])
        self.assertEqual(self.result(r), {'result': 'ok'})
        self.assertIn('combined=active width=80 owns_6g=1 freq=6135 channel=37', r.stdout)
        rec = self.record()
        self.assertEqual((rec['owns_6g'], rec['width'], rec['boot']), ('1', '80', BOOT))
        self.assertTrue(rec['tx'].endswith('/mt6639-6g/transactions/t-fixture-1'))
        self.assertEqual(oct((self.work / 'session').stat().st_mode & 0o777), '0o600')
        self.assertEqual(oct(self.work.stat().st_mode & 0o777), '0o700')
        s = self.status()
        self.assertEqual((s['hotspot_state'], s['hotspot_band'], s['hotspot_width']),
                         ('active', '6g', '80'))
        self.assertEqual((s['six_ready'], s['session_owns_6g']), ('1', '1'))

        r = self.run_op('stop')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.calls()[2:], ['hotspot stop', 'six disable'])
        self.assertEqual(self.phases(r), ['hotspot_stop', 'six_restore'])
        self.assertIsNone(self.record())
        self.assertEqual(self.status()['six_tx'], 'none')

    def test_6ghz_that_was_already_enabled_is_left_enabled(self):
        self.set_six()
        r = self.run_op('start')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.calls(), ['hotspot start 6g 20'])
        self.assertNotIn('six_enable', self.phases(r))
        self.assertEqual(self.record()['owns_6g'], '0')
        r = self.run_op('stop')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.calls(), ['hotspot start 6g 20', 'hotspot stop'])
        self.assertEqual(self.status()['six_ready'], '1')
        self.assertIsNone(self.record())

    def test_repeated_start_of_the_running_profile_is_a_no_op(self):
        self.set_six()
        self.assertEqual(self.run_op('start', '40').returncode, 0)
        r = self.run_op('start', '40')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('combined=already_active width=40', r.stdout)
        r = self.run_op('start', '160')
        self.assertEqual(r.returncode, 73)
        self.assertEqual(self.result(r)['reason'], 'hotspot_active_other_profile')
        self.assertEqual(self.result(r)['detail'], 'band=6g,width=40')
        self.assertEqual(self.calls(), ['hotspot start 6g 40'])

    def test_failed_hotspot_start_returns_6ghz_only_if_this_start_enabled_it(self):
        (self.fix / 'hot.start_rc').write_text('71\n')
        (self.fix / 'hot.start_out').write_text(
            'REJECT runner_exited_during_start reason=sta_band_incompatible_with_6g sta_freq=5180\n')
        r = self.run_op('start')
        self.assertEqual(r.returncode, 71, r.stdout + r.stderr)
        self.assertEqual(self.calls(), ['six enable', 'hotspot start 6g 20', 'six disable'])
        self.assertEqual(self.result(r), {
            'result': 'failed', 'step': 'hotspot_start', 'reason': 'runner_exited_during_start',
            'detail': 'sta_band_incompatible_with_6g', 'rc': '71'})
        self.assertIn('rollback=restored', r.stdout)
        self.assertIsNone(self.record())
        self.assertEqual(self.status()['six_tx'], 'none')

        (self.fix / 'calls').unlink()
        self.set_six()
        r = self.run_op('start')
        self.assertEqual(r.returncode, 71)
        self.assertEqual(self.calls(), ['hotspot start 6g 20'])
        self.assertEqual(self.status()['six_ready'], '1')

    def test_start_that_is_not_confirmed_active_is_torn_down(self):
        (self.fix / 'hot.start_state').write_text('unresolved\n')
        r = self.run_op('start')
        self.assertEqual(r.returncode, 69, r.stdout + r.stderr)
        self.assertEqual(self.calls(),
                         ['six enable', 'hotspot start 6g 20', 'hotspot stop', 'six disable'])
        self.assertEqual(self.result(r)['reason'], 'hotspot_not_active_after_start')
        self.assertIsNone(self.record())

    def test_start_refuses_before_any_radio_change(self):
        def missing_key(): self.key.unlink()
        def loose_key(): self.key.chmod(0o644)
        def sta_5g(): (self.fix / 'wifi').write_text(STA_5G)
        def wifi_off(): (self.fix / 'wifi').write_text('Wifi is disabled\n')
        def wifi_query_fails(): (self.fix / 'wifi').unlink()
        def no_cell(): (self.fix / 'ipaddr').write_text('    inet 127.0.0.1/8 scope host lo\n')
        def mtap(): (self.root / 'net/mtap0').mkdir(parents=True)
        def six_disabled(): (self.sixmod / 'disable').touch()
        def six_removing(): (self.sixmod / 'remove').touch()
        def six_missing(): shutil.rmtree(self.sixmod)
        def hotspot_disabled(): (self.mod / 'disable').touch()
        def tampered():
            p = self.mod / 'bin/hotspot-upstream.sh'
            p.write_text(p.read_text() + '\n# changed\n')
        def unresolved(): self.set_hotspot('unresolved')
        def status_broken(): (self.fix / 'hot.status_rc').write_text('73\n')
        def six_invalid(): self.set_six(state='active', tx='invalid')
        def six_dead_guardian(): self.set_six(guardian='not_running')
        def six_status_broken(): (self.fix / 'six.status_rc').write_text('3\n')
        cases = [
            (missing_key, {}, 'ap_key_missing', 66),
            (loose_key, {}, 'ap_key_missing', 66),
            (None, {'TEST_ENFORCE': 'Permissive'}, 'enforcing_required', 77),
            (sta_5g, {}, 'sta_band_incompatible_with_6g', 69),
            (wifi_off, {}, 'wifi_disabled', 69),
            (wifi_query_fails, {}, 'sta_status_unavailable', 69),
            (no_cell, {}, 'cellular_data_unavailable', 69),
            (None, {'TEST_TETHER_WANTED': 'true'}, 'tethering_not_idle', 73),
            (mtap, {}, 'mtap0_exists', 73),
            (six_disabled, {}, 'sixg_module_disabled', 66),
            (six_removing, {}, 'sixg_module_removing', 66),
            (six_missing, {}, 'sixg_module_missing', 66),
            (hotspot_disabled, {}, 'hotspot_module_disabled', 73),
            (tampered, {}, 'module_asset_hash_mismatch', 69),
            (None, {'TEST_DEVICE': 'other'}, 'device_mismatch', 69),
            (None, {'TEST_KERNEL': 'unknown-kernel'}, 'kernel_mismatch', 69),
            (unresolved, {}, 'hotspot_not_idle', 73),
            (status_broken, {}, 'hotspot_status_unavailable', 69),
            (six_invalid, {}, 'sixg_needs_recovery', 73),
            (six_dead_guardian, {}, 'sixg_needs_recovery', 73),
            (six_status_broken, {}, 'sixg_status_unavailable', 69),
        ]
        for arrange, env, reason, code in cases:
            with self.subTest(reason=reason, arrange=getattr(arrange, '__name__', 'env')):
                self.fresh_fixture()
                if arrange:
                    arrange()
                r = self.run_op('start', env=env)
                self.assertEqual(r.returncode, code, r.stdout + r.stderr)
                result = self.result(r)
                self.assertEqual((result['step'], result['reason']), ('preflight', reason))
                self.assertIn('REJECT ' + reason, r.stderr)
                self.assertEqual(self.phases(r), ['preflight'])
                self.assertEqual(self.calls(), [])
                self.assertIsNone(self.record())

    def fresh_fixture(self):
        """Fresh fixture for each sub-case of a table-driven test."""
        self.reap()
        self.tmp.cleanup()
        self.setUp()

    def test_failed_6ghz_enable_is_reported_and_nothing_else_runs(self):
        (self.fix / 'six.enable_rc').write_text('3\n')
        (self.fix / 'six.enable_out').write_text('[2026-11-16 02:00:00] REJECT wifi_must_be_enabled\n')
        r = self.run_op('start')
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertEqual(self.calls(), ['six enable'])
        self.assertEqual(self.result(r), {'result': 'failed', 'step': 'six_enable',
                                          'reason': 'wifi_must_be_enabled', 'detail': 'none', 'rc': '3'})
        self.assertIsNone(self.record())

    def test_enable_that_does_not_become_active_is_returned(self):
        (self.fix / 'six.enable_state').write_text('restore_failed\n')
        r = self.run_op('start')
        self.assertEqual(r.returncode, 69, r.stdout + r.stderr)
        self.assertEqual(self.calls(), ['six enable', 'six disable'])
        self.assertEqual(self.result(r)['reason'], 'sixg_not_active_after_enable')

    def test_station_that_rejoins_another_band_after_the_wifi_restart_rolls_back(self):
        (self.fix / 'wifi.after_enable').write_text(STA_5G)
        r = self.run_op('start')
        self.assertEqual(r.returncode, 69, r.stdout + r.stderr)
        self.assertEqual(self.calls(), ['six enable', 'six disable'])
        result = self.result(r)
        self.assertEqual((result['step'], result['reason']),
                         ('preflight', 'sta_band_incompatible_with_6g'))
        self.assertEqual(result['detail'], 'upstream=wifi-any,sta_freq=5180')
        self.assertEqual(self.phases(r), ['preflight', 'six_enable', 'sta_settle', 'six_rollback'])
        self.assertIsNone(self.record())

    def test_lock_is_not_inherited_and_serializes_operations(self):
        self.assertEqual(self.run_op('start').returncode, 0)
        # The guardian and runner doubles are still alive and hold every
        # descriptor they inherited; the lock must be free regardless.
        self.assertTrue(self.lock_free())
        before = self.calls()
        with (self.work / 'control.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            r = self.run_op('stop')
            self.assertEqual(r.returncode, 75, r.stdout + r.stderr)
            self.assertIn('REJECT radio_control_busy', r.stderr)
            self.assertEqual(self.result(r)['reason'], 'radio_control_busy')
            self.assertEqual(self.status()['busy'], '1')
            full = self.status('full')
            self.assertEqual((full['mode'], full['busy'], full['hotspot_checked']), ('light', '1', '0'))
            self.assertEqual(self.run_op('set-width', '40').returncode, 75)
        self.assertEqual(self.calls(), before)
        self.assertEqual(self.status()['busy'], '0')

    def test_ownership_survives_a_hotspot_stopped_some_other_way(self):
        self.assertEqual(self.run_op('start').returncode, 0)
        self.set_hotspot('idle')
        r = self.run_op('start', '160')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.calls(), ['six enable', 'hotspot start 6g 20', 'hotspot start 6g 160'])
        self.assertEqual((self.record()['owns_6g'], self.record()['width']), ('1', '160'))
        self.assertEqual(self.run_op('stop').returncode, 0)
        self.assertEqual(self.calls()[3:], ['hotspot stop', 'six disable'])

    def test_a_replaced_transaction_is_not_returned(self):
        self.assertEqual(self.run_op('start').returncode, 0)
        # The user restored and re-enabled 6GHz by hand: a different transaction.
        self.set_six(tx='t-someone-else')
        r = self.run_op('stop')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.calls()[2:], ['hotspot stop'])
        self.assertIsNone(self.record())
        self.assertEqual(self.status()['six_ready'], '1')

    def test_record_from_another_boot_or_malformed_never_disables_6ghz(self):
        tx = f'{self.adb}/mt6639-6g/transactions/t-fixture-0'
        good = f'schema=mt6639-radio-session-v1\nboot={BOOT}\nowns_6g=1\ntx={tx}\nwidth=20\n'
        self.work.mkdir(mode=0o700)
        for name, text in [
            ('other_boot', good.replace(BOOT, OTHER_BOOT)),
            ('schema', good.replace('session-v1', 'session-v0')),
            ('owns', good.replace('owns_6g=1', 'owns_6g=2')),
            ('tx_escape', good.replace(tx, tx + '/../../x')),
            ('tx_foreign', good.replace(tx, '/data/local/tmp/t-x')),
            ('width', good.replace('width=20', 'width=21')),
            ('garbage', 'owns_6g=1\n' * 400),
        ]:
            with self.subTest(case=name):
                self.set_six()
                self.set_hotspot('active')
                (self.fix / 'calls').unlink(missing_ok=True)
                (self.work / 'session').write_text(text)
                # A read-only status neither trusts nor removes it.
                self.assertEqual(self.status()['session_owns_6g'], '0')
                self.assertTrue((self.work / 'session').exists())
                r = self.run_op('stop')
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertEqual(self.calls(), ['hotspot stop'])
                self.assertFalse((self.work / 'session').exists())
        self.assertTrue(list(self.work.glob('session.invalid.*')))
        # A link in place of the record is set aside, never followed.
        target = self.root / 'elsewhere'
        target.write_text(good)
        (self.work / 'session').symlink_to(target)
        self.set_hotspot('active')
        self.assertEqual(self.run_op('stop').returncode, 0)
        self.assertNotIn('six disable', self.calls())
        self.assertFalse((self.work / 'session').is_symlink())
        self.assertEqual(target.read_text(), good)

    def test_stop_failure_keeps_the_record_so_a_retry_can_finish(self):
        self.assertEqual(self.run_op('start').returncode, 0)
        (self.fix / 'six.disable_rc').write_text('90\n')
        (self.fix / 'six.disable_out').write_text('[ts] FAIL native guardian_did_not_terminate\n')
        r = self.run_op('stop')
        self.assertEqual(r.returncode, 90, r.stdout + r.stderr)
        self.assertEqual(self.result(r), {'result': 'failed', 'step': 'six_restore',
                                          'reason': 'sixg_restore_failed', 'detail': 'none', 'rc': '90'})
        self.assertEqual(self.record()['owns_6g'], '1')
        (self.fix / 'six.disable_rc').write_text('0\n')
        r = self.run_op('stop')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.calls()[2:], ['hotspot stop', 'six disable', 'six disable'])
        self.assertIsNone(self.record())

    def test_hotspot_stop_failure_leaves_6ghz_and_the_record_alone(self):
        self.assertEqual(self.run_op('start').returncode, 0)
        (self.fix / 'hot.stop_rc').write_text('73\n')
        (self.fix / 'hot.stop_out').write_text('REJECT interface_still_present\n')
        r = self.run_op('stop')
        self.assertEqual(r.returncode, 73)
        self.assertEqual(self.result(r)['reason'], 'interface_still_present')
        self.assertEqual(self.calls()[2:], ['hotspot stop'])
        self.assertEqual(self.record()['owns_6g'], '1')

    def test_stop_with_an_unreadable_6ghz_status_keeps_the_record(self):
        self.assertEqual(self.run_op('start').returncode, 0)
        (self.sixmod / 'bin/control.sh').write_text('#!/bin/sh\nexit 3\n')
        r = self.run_op('stop')
        self.assertEqual(r.returncode, 69, r.stdout + r.stderr)
        self.assertEqual(self.result(r)['reason'], 'sixg_status_unavailable')
        self.assertEqual(self.record()['owns_6g'], '1')
        # An uninstalled 6GHz module leaves nothing to return.
        shutil.rmtree(self.sixmod)
        self.set_hotspot('active')
        self.assertEqual(self.run_op('stop').returncode, 0)
        self.assertIsNone(self.record())

    def test_6ghz_switch_is_independent_and_protects_a_running_hotspot(self):
        r = self.run_op('six-on')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.calls(), ['six enable'])
        self.assertIsNone(self.record())
        self.assertIn('six=already_active', self.run_op('six-on').stdout)
        # Enabled by the user: a later one-tap session must not take it away.
        self.assertEqual(self.run_op('start').returncode, 0)
        for op in ('six-off', 'six-refresh'):
            r = self.run_op(op)
            self.assertEqual(r.returncode, 73, r.stdout + r.stderr)
            self.assertEqual(self.result(r)['reason'], 'hotspot_active')
        self.assertEqual(self.run_op('stop').returncode, 0)
        self.assertEqual(self.calls(), ['six enable', 'hotspot start 6g 20', 'hotspot stop'])
        self.assertEqual(self.run_op('six-refresh').returncode, 0)
        r = self.run_op('six-off')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.calls()[3:], ['six refresh', 'six disable'])
        self.assertEqual(self.status()['six_tx'], 'none')

    def test_6ghz_switch_reports_the_module_reason(self):
        (self.fix / 'six.refresh_rc').write_text('3\n')
        (self.fix / 'six.refresh_out').write_text('[ts] refresh-6g: FAIL state_not_active\n')
        r = self.run_op('six-refresh')
        self.assertEqual((r.returncode, self.result(r)['reason']), (3, 'state_not_active'))
        self.set_six(guardian='not_running')
        r = self.run_op('six-on')
        self.assertEqual((r.returncode, self.result(r)['reason']), (73, 'sixg_needs_recovery'))
        self.assertEqual(self.calls(), ['six refresh'])

    def test_width_preference_is_validated_and_used_by_default(self):
        self.assertEqual(self.status()['pref_width'], '20')
        r = self.run_op('set-width', '160')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.status()['pref_width'], '160')
        self.set_six()
        self.assertEqual(self.run_op('start').returncode, 0)
        self.assertEqual(self.calls(), ['hotspot start 6g 160'])
        for bad in ('30', '0', '160;id', '$(id)', '-1', ' 20'):
            self.assertEqual(self.run_op('set-width', bad).returncode, 64, bad)
            self.assertEqual(self.run_op('start', bad).returncode, 64, bad)
        self.assertEqual(self.run_op('set-width').returncode, 64)
        self.assertEqual(self.status()['pref_width'], '160')
        # A value that was not written by this controller falls back safely.
        (self.work / 'width').write_text('999\n')
        self.assertEqual(self.status()['pref_width'], '20')
        conf = self.mod / 'config.conf'
        conf.write_text(conf.read_text().replace('WIDTH=${WIDTH:-20}', 'WIDTH=${WIDTH:-80}'))
        self.assertEqual(self.status()['pref_width'], '80')

    def test_action_button_toggles_both_layers(self):
        r = self.run_op('toggle')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.calls(), ['six enable', 'hotspot start 6g 20'])
        self.assertIn('一键开启', r.stdout)
        self.assertIn('完成。', r.stdout)
        r = self.run_op('toggle')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.calls()[2:], ['hotspot stop', 'six disable'])
        self.assertIn('一键关闭', r.stdout)
        self.key.unlink()
        r = self.run_op('toggle')
        self.assertEqual(r.returncode, 66)
        self.assertIn('未完成：ap_key_missing', r.stdout)
        action = (self.mod / 'action.sh').read_text()
        self.assertIn('bin/radio-control.sh" "$MODDIR" toggle', action)

    def test_action_button_keeps_the_single_layer_toggle_for_another_band(self):
        conf = self.mod / 'config.conf'
        conf.write_text(conf.read_text().replace('BAND=${BAND:-6g}', 'BAND=${BAND:-5g}'))
        r = self.run_op('toggle')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.calls(), ['hotspot toggle'])
        self.assertIn('legacy-toggle', r.stdout)

    def test_running_hotspot_action_is_not_interrupted_by_a_status_check(self):
        with (self.hot_work / 'action.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            full = self.status('full')
            self.assertEqual((full['mode'], full['hotspot_checked']), ('full', '0'))
            self.assertFalse((self.fix / 'calls').exists())
            r = self.run_op('start')
            self.assertEqual((r.returncode, self.result(r)['reason']), (75, 'hotspot_busy'))
            r = self.run_op('stop')
            self.assertEqual((r.returncode, self.result(r)['reason']), (75, 'hotspot_busy'))
        self.assertEqual(self.calls(), [])

    def test_usage_identity_and_private_work_directory(self):
        self.assertEqual(self.run_op('status', moddir='/tmp/elsewhere').returncode, 64)
        for args in (('bogus',), ('status', 'verbose'), ('stop', 'now'), ('start', '20', 'x'),
                     ('logs', 'all')):
            self.assertEqual(self.run_op(*args).returncode, 64, args)
        self.assertEqual(self.run_op('status', env={'TEST_UID': '2000'}).returncode, 77)
        self.assertEqual(self.run_op('start', env={'TEST_CONTEXT': 'u:r:shell:s0'}).returncode, 77)
        self.assertEqual(self.run_op('start', env={'TEST_OWNER': '2000'}).returncode, 77)
        self.assertFalse(self.work.exists())
        elsewhere = self.root / 'elsewhere'
        elsewhere.mkdir()
        self.work.symlink_to(elsewhere)
        self.assertEqual(self.run_op('start').returncode, 77)
        self.assertEqual(list(elsewhere.iterdir()), [])
        self.work.unlink()
        self.work.mkdir(mode=0o777)
        self.work.chmod(0o777)
        self.assertEqual(self.run_op('status').returncode, 0)
        self.assertEqual(oct(self.work.stat().st_mode & 0o777), '0o700')
        self.assertEqual(self.calls(), [])

    def test_logs_show_operations_without_the_key(self):
        self.assertEqual(self.run_op('start', '40').returncode, 0)
        (self.hot_work / 'control.log').write_text('2026-11-16 02:00:00 state=active\n')
        r = self.run_op('logs')
        self.assertEqual(r.returncode, 0)
        for section in ('=== radio ===', '=== hotspot ===', '=== sixg ==='):
            self.assertIn(section, r.stdout)
        self.assertIn('op=start arg=40 begin', r.stdout)
        self.assertIn('op=start end rc=0', r.stdout)
        self.assertIn('state=active', r.stdout)
        self.assertNotIn('fixture-password', r.stdout)

    def test_shell_syntax(self):
        for name in ('bin/radio-control.sh', 'bin/radio-key.sh', 'action.sh'):
            r = subprocess.run(['sh', '-n', str(HOTSPOT / name)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
        source = (HOTSPOT / 'bin/radio-control.sh').read_text()
        self.assertNotIn('rm -rf', source)
        self.assertNotIn('su -c', source)
        # Every child of the controller is started without the lock descriptor.
        for line in source.splitlines():
            if ('sh "$SIX/bin/' in line or 'sh "$HOTSPOT/bin/' in line) and 'exec sh' not in line:
                self.assertIn('8>&-', line, line)


class RadioContractTests(RadioFixture):
    """The real status entry points, with Android I/O doubled."""
    real_hotspot = True

    def test_real_hotspot_controller_and_snapshot_fields_are_understood(self):
        full = self.status('full')
        self.assertEqual((full['hotspot_checked'], full['hotspot_status_rc']), ('1', '0'))
        self.assertEqual((full['hotspot_state'], full['hotspot_snapshot']), ('idle', '1'))
        self.assertEqual((full['hotspot_band'], full['hotspot_width']), ('none', 'none'))
        # Band and width exist only in the published snapshot; the controller's
        # status output has neither line.
        publish = subprocess.run(
            ['sh', str(self.mod / 'bin/status_snapshot.sh'), str(self.mod), 'publish',
             'active', '6g', '160'], env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(publish.returncode, 0, publish.stdout + publish.stderr)
        light = self.status()
        self.assertEqual((light['hotspot_state'], light['hotspot_band'], light['hotspot_width']),
                         ('active', '6g', '160'))
        self.assertIn(light['hotspot_age'], ('0', '1', '2', '3'))
        direct = subprocess.run(['sh', str(self.mod / 'bin/control.sh'), str(self.mod), 'status'],
                                env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(direct.returncode, 0, direct.stderr)
        self.assertNotIn('band=', direct.stdout)
        self.assertNotIn('width=', direct.stdout)

    def test_snapshot_from_another_boot_or_with_unknown_values_is_not_used(self):
        self.status('full')
        snapshot = self.misc / 'mt6639-hotspot/status'
        good = snapshot.read_text()
        for text in (good.replace(BOOT, OTHER_BOOT), good.replace('state=idle', 'state=$(id)'),
                     good.replace('band=none', 'band=60g'), good.replace('status-v3', 'status-v2')):
            snapshot.write_text(text)
            s = self.status()
            self.assertEqual((s['hotspot_snapshot'], s['hotspot_state']), ('0', 'unknown'))
        target = self.root / 'snapshot-target'
        target.write_text(good)
        snapshot.unlink()
        snapshot.symlink_to(target)
        self.assertEqual(self.status()['hotspot_snapshot'], '0')

    def test_real_6ghz_status_fields_are_understood(self):
        shutil.rmtree(self.sixmod)
        shutil.copytree(SIX, self.sixmod)
        six_work = self.adb / 'mt6639-6g'
        cfg, ko = self.root / 'cfg', self.root / 'ko'
        cfg.write_text('CountryCode=CN\n')
        ko.write_text('stock ko\n')
        env = dict(
            MT6639_TEST_MODE='1', WORK=str(six_work), CFG=str(cfg), STOCK_KO=str(ko),
            STOCK_CFG_SHA=hashlib.sha256(cfg.read_bytes()).hexdigest(),
            STOCK_KO_SHA=hashlib.sha256(ko.read_bytes()).hexdigest(),
            BOOT_ID_FILE=str(self.bootfile), TEST_OWNER=str(os.getuid()))
        # hotspot work directory checks expect root's uid from the stat double.
        def status():
            r = self.run_op('status', env=env)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            return dict(line.split('=', 1) for line in r.stdout.splitlines() if '=' in line)

        self.env['TEST_OWNER'] = str(os.getuid())
        s = status()
        self.assertEqual((s['six_status_rc'], s['six_tx'], s['six_guardian']), ('0', 'none', 'none'))
        self.assertEqual((s['six_state'], s['six_profile'], s['six_compat_error']),
                         ('none', 'fixture', 'none'))
        self.assertEqual((s['six_boot_default'], s['six_ready']), ('1', '0'))

        tx = six_work / 'transactions/t-11111111-1700000000-AbCdEf'
        tx.mkdir(parents=True)
        (six_work / 'active_tx').write_text(str(tx) + '\n')
        (six_work / 'state').write_text('active\n')
        s = status()
        # A transaction without a live guardian is present but not ready.
        self.assertEqual((s['six_tx'], s['six_state'], s['six_guardian'], s['six_ready']),
                         ('present', 'active', 'not_running', '0'))
        (six_work / 'active_tx').write_text('/somewhere/else\n')
        s = status()
        self.assertEqual((s['six_status_rc'], s['six_tx'], s['six_ready']), ('3', 'invalid', '0'))


if __name__ == '__main__':
    unittest.main()
