"""Static guards for the native AP resource-recovery boundary."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "tools/softap_native_once.sh").read_text(encoding="utf-8")
START = SOURCE.index("recover() {")
END = SOURCE.index('\n}\ncase "$OP" in', START)
RECOVER = SOURCE[START:END]


class NativeRecoverySourceTests(unittest.TestCase):
    def test_guardian_is_told_the_session_band(self):
        # The guardian re-executes this script; without the band it falls back
        # to the 6GHz defaults and its recovery cannot find reconnect-2g.key.
        self.assertIn('"$SELF" "$D" guardian "$BAND" "$WIDTH"', SOURCE)
        # And the task records its band, so any argument-less sub-invocation
        # still resolves the same profile instead of defaulting to 6GHz.
        self.assertIn('printf \'%s\\n\' "$BAND" > "$D/band"', SOURCE)
        self.assertIn('BAND=$(cat "$D/band" 2>/dev/null || true)', SOURCE)

    def test_recovery_journals_each_resource_and_has_terminal_result(self):
        for key in (
            "tether_state", "native_state", "interface_state", "driver_state",
            "station_state", "reg_state", "ip_forward_state", "journal_ok",
        ):
            with self.subTest(key=key):
                self.assertIn(key, RECOVER)
        self.assertIn('printf \'%s\\n\' "$rc" > "$D/recovery.rc"', RECOVER)
        self.assertIn(': > "$D/guardian.done"', RECOVER)
        self.assertNotIn("return 73", RECOVER)
        self.assertNotIn("return 69", RECOVER)

    def test_shared_tether_stop_requires_task_interface_identity(self):
        stop = RECOVER.index("NativeTether stop")
        iface = RECOVER.index('[ "$(cat "/sys/class/net/$IF/ifindex")" = "$(cat "$D/interface.index")" ]')
        self.assertLess(iface, stop)
        self.assertIn("stopTetheringRequest", (ROOT / "native/framework/NativeTether.java").read_text())
        self.assertIn("unresolved_interface_owner", RECOVER)
        self.assertIn("tether_safe=0", RECOVER)

    def test_hostapd_recovery_uses_private_executable_and_config_identity(self):
        self.assertIn('native_process_matches "$p"', RECOVER)
        self.assertIn('case "$probe_cmd" in *"$D/ap.conf"*)', SOURCE)
        self.assertIn("unresolved_process_identity", RECOVER)
        self.assertIn("unresolved_orphan_alive", RECOVER)

    def test_netdev_delete_and_driver_restore_require_safe_radio_state(self):
        delete = RECOVER.index('"$D/delete_ifindex"')
        driver = RECOVER.index('set_ap "$before"')
        self.assertIn('[ "$native_safe" = 1 ] && [ "$tether_safe" = 1 ]; then', RECOVER[:delete])
        self.assertIn('[ "$(cat "/sys/class/net/$IF/ifindex")" = "$(cat "$D/interface.index")" ]; then', RECOVER[:delete])
        helper = (ROOT / "native/netdev/delete_ifindex.c").read_text()
        self.assertIn("NL80211_CMD_DEL_INTERFACE", helper)
        self.assertIn("NL80211_ATTR_IFINDEX", helper)
        self.assertIn('radio_safe=1', RECOVER)
        self.assertIn('[ "$radio_safe" = 1 ] && [ "$journal_ok" = 1 ]', RECOVER[:driver])
        self.assertIn("deferred_radio_or_backup_unresolved", RECOVER)
        self.assertIn('[ "$tether_safe" = 1 ]; then', RECOVER[:delete])

    def test_station_selection_is_blocked_when_resources_are_unresolved(self):
        select = RECOVER.index('"$D/twt_recover.sh" select')
        gate = RECOVER.rfind('[ "$station_safe" = 1 ] && [ "$journal_ok" = 1 ]', 0, select)
        self.assertGreaterEqual(gate, 0)
        self.assertIn('[ "$driver_safe" = 1 ] && [ "$reg_state" = restored ]', RECOVER)
        self.assertIn('check_dir=$D/network-recover-$$', RECOVER)
        self.assertIn("deferred_unresolved_resources", RECOVER)


class UpstreamModeSourceTests(unittest.TestCase):
    """The uplink contract must be decided once, recorded, and honoured twice."""

    def test_auto_mode_is_resolved_and_recorded(self):
        helper = (ROOT / "modules/mt6639-hotspot/bin/hotspot-upstream.sh").read_text()
        self.assertIn('"$D/hotspot-upstream.sh" "${MT6639_HOTSPOT_UPSTREAM:-auto}" "$BAND" "$D/sta.before"', SOURCE)
        self.assertIn("auto|wifi|wifi-any|cell", helper)
        self.assertIn('request=cell', helper)
        self.assertIn('request=wifi-any', helper)
        self.assertIn('printf \'%s\\n\' "$UPSTREAM_MODE" > "$D/upstream.mode"', SOURCE)
        # auto must inspect the live STA state before it writes the record
        self.assertLess(SOURCE.index('cmd wifi status > "$D/sta.before"'),
                        SOURCE.index('> "$D/upstream.mode"'))

    def test_cell_mode_requires_loaded_driver_and_no_sta_and_cellular_data(self):
        self.assertIn("wifi_disabled_driver_unavailable", SOURCE)
        self.assertIn("sta_connected_in_cell_mode", SOURCE)
        self.assertIn("cellular_data_unavailable", SOURCE)
        self.assertIn('grep -Fxq \'Wifi is enabled\' "$D/sta.before"', SOURCE)
        self.assertIn('inet [0-9.]+/.* (rmnet|ccmni|wwan)[0-9]*', SOURCE)
        # every cell gate must run before the first driver mutation
        first_intent = SOURCE.index(': > "$D/driver.intent"')
        for reason in ("wifi_disabled_driver_unavailable", "sta_connected_in_cell_mode",
                       "cellular_data_unavailable"):
            with self.subTest(reason=reason):
                self.assertLess(SOURCE.index(reason), first_intent)

    def test_upstream_assertion_is_per_mode_and_reports_actual_interface(self):
        self.assertIn(r"cell) UPSTREAM_RE='Current upstream interface\(s\): \[(rmnet|wwan|ccmni|seth|eth)'", SOURCE)
        self.assertIn(r"*) UPSTREAM_RE='Current upstream interface\(s\): \[wlan0\]' ;;", SOURCE)
        self.assertIn("upstream_mismatch mode=%s actual=%s", SOURCE)

    def test_recovery_releases_station_duty_only_when_mode_never_owned_it(self):
        self.assertIn('recover_mode=$(cat "$D/upstream.mode"', RECOVER)
        self.assertIn("wifi) station_required=1 ;;", RECOVER)
        self.assertIn("*) station_required=0 ;;", RECOVER)
        self.assertIn("station_state=not_required_$recover_mode", RECOVER)
        # the enforced reconnect path must stay reachable for the wifi baseline
        self.assertIn('"$D/twt_recover.sh" select', RECOVER)


class SixGhzBandGateSourceTests(unittest.TestCase):
    """The driver moves a 6135MHz AP onto the STA channel; refuse that up front."""

    def test_sta_on_non_6ghz_channel_is_rejected_before_any_driver_mutation(self):
        self.assertIn("sta_band_incompatible_with_6g sta_freq=%s", SOURCE)
        self.assertIn("sta_frequency_unknown", SOURCE)
        gate = SOURCE.index("sta_band_incompatible_with_6g")
        self.assertLess(gate, SOURCE.index(': > "$D/driver.intent"'))
        self.assertIn('[ "$sta_freq" -lt 5950 ] || [ "$sta_freq" -gt 7125 ]', SOURCE)
        # cell mode has no STA at all, so the gate must not apply to it
        self.assertIn('[ "$BAND" = 6g ] && [ "$UPSTREAM_MODE" != cell ]', SOURCE)

    def test_final_self_check_records_why_it_failed(self):
        self.assertIn("final_check_failed", SOURCE)
        final_block = SOURCE[SOURCE.index('Detect a channel switch'):]
        self.assertIn('> "$D/failure"', final_block)


class FailedStartCloseoutTests(unittest.TestCase):
    """A start that already tore everything down must not pin 'starting'."""

    CONTROL = (ROOT / "modules/mt6639-hotspot/bin/control.sh").read_text(encoding="utf-8")

    def test_runner_exit_after_checked_teardown_clears_the_session(self):
        block = self.CONTROL[self.CONTROL.index("runner_exited_during_start reason=unreported"):]
        self.assertIn('[ "$(cat "$task/recovery.rc" 2>/dev/null)" = 0 ]', block)
        self.assertIn("[ ! -e /sys/class/net/mtap0 ]", block)
        self.assertIn("if clear_session; then", block)
        # still a failed start: the caller must not report success
        self.assertIn("return 71", block)

    def test_runner_exit_before_any_effect_also_clears_the_session(self):
        block = self.CONTROL[self.CONTROL.index("runner_exited_during_start reason=unreported"):]
        for marker in ("driver.intent", "interface.intent", "tether.intent"):
            with self.subTest(marker=marker):
                self.assertIn('[ ! -e "$task/%s" ]' % marker, block)
        self.assertIn("start_no_effect=1", block)


if __name__ == "__main__":
    unittest.main()
