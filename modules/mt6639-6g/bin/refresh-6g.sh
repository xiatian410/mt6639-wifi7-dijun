#!/system/bin/sh
# Rebuild Wi-Fi only when an active 6GHz transaction is intact but the current
# driver/userland generation has no 6GHz channels registered.
set -u
MODDIR=${1:-${MODDIR:-/data/adb/modules/mt6639-6g}}
. "$MODDIR/bin/owner.sh"
require_owner_mutation || exit 3
if [ "$MODULE_EMBEDDED" = 1 ]; then require_owner_enabled || exit 3; fi
. "$MODDIR/bin/lib.sh"
[ -f "$MODDIR/config.conf" ] && . "$MODDIR/config.conf"

fail() {
    code=$1
    shift
    log "refresh-6g: FAIL $*"
    exit "$code"
}

[ "$(id -u)" = 0 ] || fail 3 not_root
[ "$(id -Z 2>/dev/null)" = u:r:ksu:s0 ] || fail 3 ksu_context_required
[ "$(getenforce 2>/dev/null)" = Enforcing ] || fail 3 enforcing_required
[ "${ENABLE_6G:-0}" = 1 ] || fail 3 module_disabled

if [ "${MT6639_TEST_MODE:-0}" = 1 ] && [ -n "${MT6639_TEST_STATUS_FILE:-}" ]; then
    status=$(cat "$MT6639_TEST_STATUS_FILE") || fail 3 status_unreadable
else
    status=$(timeout 15 sh "$MODDIR/bin/native.sh" "$MODDIR" status 2>&1) ||
        fail 3 status_unreadable
fi
printf '%s\n' "$status" | grep -qx 'enabled_config=1' || fail 3 config_not_enabled
printf '%s\n' "$status" | grep -qx 'state=active' || fail 3 state_not_active
printf '%s\n' "$status" | grep -qx 'guardian=alive' || fail 3 guardian_not_alive

tx=$(printf '%s\n' "$status" | sed -n 's/^active_tx=//p' | head -1)
case "$tx" in
    "$WORK"/transactions/t-*) ;;
    *) fail 3 transaction_invalid ;;
esac
[ -d "$tx" ] && [ ! -L "$tx" ] || fail 3 transaction_missing
[ "$(cat "$tx/wrapper-boot" 2>/dev/null)" = "$(boot_id)" ] ||
    fail 3 transaction_boot_mismatch
[ "$(file_sha "$CFG")" = "$(file_sha "$tx/candidate")" ] ||
    fail 3 active_cfg_mismatch
mountinfo=$(cat "$MOUNTINFO_FILE" 2>/dev/null) || fail 3 mountinfo_unreadable
printf '%s\n' "$mountinfo" | awk -v target="$CFG" '
    $5 == target { found=1 } END { exit(found ? 0 : 1) }' ||
    fail 3 active_cfg_not_mounted

sixg_count() {
    dump=$WORK/iw-phy.refresh.$$
    if ! iw phy >"$dump" 2>&1; then
        rm -f "$dump"
        return 2
    fi
    awk '
        /^[[:space:]]*\* [0-9]+(\.[0-9]+)? MHz/ {
            if ($0 ~ /\(disabled\)/) next
            mhz=$2
            sub(/\..*/, "", mhz)
            gsub(/[^0-9]/, "", mhz)
            if (mhz == 6135) count++
        }
        END { print count + 0 }
    ' "$dump"
    rc=$?
    rm -f "$dump"
    return "$rc"
}

before=$(sixg_count) || fail 3 iw_phy_failed
if [ "$before" -gt 0 ]; then
    log "refresh-6g: already_registered target_6135=$before"
    echo 'RESULT refresh=already_registered'
    exit 0
fi

if [ "${MT6639_TEST_MODE:-0}" = 1 ] && [ -n "${MT6639_TEST_READY_FILE:-}" ]; then
    ready=$(cat "$MT6639_TEST_READY_FILE") || fail 3 country_baseline_unreadable
else
    ready=$(timeout 15 sh "$MODDIR/bin/native.sh" "$MODDIR" ready 2>&1) ||
        fail 3 country_baseline_unreadable
fi
country_override=$(printf '%s\n' "$ready" |
    sed -n 's/.*"country_override":\([01]\).*/\1/p')
country_code=$(printf '%s\n' "$ready" |
    sed -n 's/.*"override_code":"\([A-Z][A-Z]\)".*/\1/p')
case "$country_override" in
    0) country_code= ;;
    1)
        case "$country_code" in US|CN) ;; *) fail 3 country_baseline_invalid ;; esac
        ;;
    *) fail 3 country_baseline_invalid ;;
esac
country_changed=0
restore_country_after_failure() {
    [ "$country_changed" = 1 ] || return 0
    if [ "$country_override" = 1 ]; then
        wifi force-country-code enabled "$country_code" >/dev/null 2>&1 ||
            log 'refresh-6g: FAIL country_restore_after_failure'
    else
        wifi force-country-code disabled >/dev/null 2>&1 ||
            log 'refresh-6g: FAIL country_restore_after_failure'
    fi
}

scan_was=$(read_setting wifi_scan_always_enabled) || fail 3 scan_baseline_unreadable
case "$scan_was" in 0|1) ;; *) fail 3 scan_baseline_invalid ;; esac
wifi_was=$(read_setting wifi_on) || fail 3 wifi_baseline_unreadable
[ "$wifi_was" = 1 ] || fail 3 wifi_must_be_enabled

restore_scan_after_failure() {
    sh_shell "settings put global wifi_scan_always_enabled $scan_was" \
        >/dev/null 2>&1 ||
        log 'refresh-6g: FAIL scan_restore_after_failure'
}

cleanup_on_signal() {
    code=$1
    trap - HUP INT TERM
    log "refresh-6g: interrupted signal_rc=$code cleanup=begin"
    wifi set-wifi-enabled enabled >/dev/null 2>&1 ||
        log 'refresh-6g: FAIL wifi_restore_after_signal'
    restore_country_after_failure
    restore_scan_after_failure
    log "refresh-6g: interrupted cleanup=done"
    exit "$code"
}
trap 'cleanup_on_signal 129' HUP
trap 'cleanup_on_signal 130' INT
trap 'cleanup_on_signal 143' TERM

log "refresh-6g: rebuilding Wi-Fi target_6135=$before"
wifi set-scan-always-available disabled >/dev/null 2>&1 ||
    fail 90 wifi_scan_off_failed
if [ "$country_override" != 1 ] || [ "$country_code" != US ]; then
    country_changed=1
    wifi force-country-code enabled US >/dev/null 2>&1 || {
        restore_country_after_failure
        restore_scan_after_failure
        fail 90 country_us_failed
    }
    country_now=$(wifi get-country-code 2>/dev/null | sed 's/.* //')
    [ "$country_now" = US ] || {
        restore_country_after_failure
        restore_scan_after_failure
        fail 90 country_us_readback_failed
    }
fi
wifi set-wifi-enabled disabled >/dev/null 2>&1 || {
    restore_country_after_failure
    restore_scan_after_failure
    fail 90 wifi_off_failed
}
sleep 8
if ! wifi set-wifi-enabled enabled >/dev/null 2>&1; then
    log 'refresh-6g: wifi_on_failed retry=1'
    sleep 3
    wifi set-wifi-enabled enabled >/dev/null 2>&1 || {
        restore_country_after_failure
        restore_scan_after_failure
        fail 90 wifi_on_failed
    }
fi
sleep 12
sh_shell "settings put global wifi_scan_always_enabled $scan_was" >/dev/null 2>&1 ||
    { restore_country_after_failure; fail 90 scan_restore_failed; }

scan_now=$(read_setting wifi_scan_always_enabled) ||
    { restore_country_after_failure; fail 90 scan_readback_failed; }
[ "$scan_now" = "$scan_was" ] ||
    { restore_country_after_failure; fail 90 scan_readback_mismatch; }
wifi_now=$(read_setting wifi_on) ||
    { restore_country_after_failure; fail 90 wifi_readback_failed; }
[ "$wifi_now" = 1 ] ||
    { restore_country_after_failure; fail 90 wifi_readback_mismatch; }
country_now=$(wifi get-country-code 2>/dev/null | sed 's/.* //')
[ "$country_now" = US ] || {
    restore_country_after_failure
    fail 90 country_us_missing_after_rebuild
}

attempt=0
after=0
while [ "$attempt" -lt 6 ]; do
    after=$(sixg_count) || fail 90 iw_phy_after_failed
    [ "$after" -gt 0 ] && break
    attempt=$((attempt+1))
    [ "$attempt" -ge 6 ] || sleep 5
done
[ "$after" -gt 0 ] || {
    restore_country_after_failure
    log "refresh-6g: target_6135_missing after_rebuild before=$before after=$after"
    echo 'RESULT refresh=not_registered'
    exit 4
}
log "refresh-6g: target_6135_registered before=$before after=$after"
echo 'RESULT refresh=registered'
