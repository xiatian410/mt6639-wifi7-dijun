#!/system/bin/sh
# 恢复原厂：取消 bind、恢复 Wi-Fi 与扫描设置、复核原厂哈希。
# 幂等：没有挂载时也安全返回，可重复执行。
set -u
MODDIR=${1:-${MODDIR:-/data/adb/modules/mt6639-6g}}
. "$MODDIR/bin/owner.sh"
require_owner_mutation || exit 3
. "$MODDIR/bin/lib.sh"

if [ "${NATIVE_EXECUTOR:-1}" = 1 ]; then
    exec sh "$MODDIR/bin/control.sh" "$MODDIR" disable
fi

log "=== restore start ==="
[ "$(id -u)" = 0 ] || { log "REJECT not_root"; exit 3; }

grep -q " $CFG " "$MOUNTINFO_FILE"
mounted_rc=$?
[ "$mounted_rc" -le 1 ] || { log 'REJECT mountinfo_unreadable'; exit 90; }
if [ ! -f "$SCAN_GUARD_FILE" ] && [ "$mounted_rc" = 1 ]; then
    # No recorded experiment: do not change global settings just to be idempotent.
    [ "$(file_sha "$CFG")" = "$STOCK_CFG_SHA" ] || { log 'FAIL idle_cfg_not_stock'; exit 90; }
    log 'idle: no recorded experiment, no radio changes'
    exit 0
fi
current_boot=$(boot_id)
[ -n "$current_boot" ] && [ "$(cat "$BOOT_GUARD_FILE" 2>/dev/null)" = "$current_boot" ] || {
    log 'REJECT boot_guard'; echo recovery_blocked > "$STATE"; exit 90; }
scan_before=$(cat "$SCAN_GUARD_FILE" 2>/dev/null)
case "$scan_before" in 0|1) ;; *) log 'REJECT scan_baseline'; echo recovery_blocked > "$STATE"; exit 90 ;; esac

ok=1
grep -q " $CFG " "$MOUNTINFO_FILE"
mounted_rc=$?
[ "$mounted_rc" -le 1 ] || { log 'REJECT mountinfo_unreadable'; exit 90; }
if [ "$mounted_rc" = 0 ]; then
    umount "$CFG" 2>/dev/null && log "unmounted" || { log "FAIL unmount"; ok=0; }
else
    log "not mounted (nothing to do)"
fi

if [ "$ok" = 1 ]; then
    restore_wifi_cycle "$scan_before" || ok=0
fi

cfg_sha=$(file_sha "$CFG")
log "cfg_sha=$cfg_sha"
if [ "$cfg_sha" != "$STOCK_CFG_SHA" ]; then
    log "FAIL cfg_not_restored"
    ok=0
fi

country=$(wifi get-country-code 2>&1 | tr -d '\r')
log "country=$country"
scan=$(read_setting wifi_scan_always_enabled) || { log 'FAIL scan_read'; ok=0; }
log "scan_always=$scan"
[ "$scan" = "$scan_before" ] || { log 'FAIL scan_readback'; ok=0; }
wifi_now=$(read_setting wifi_on) || { log 'FAIL wifi_read'; ok=0; }
log "wifi_enabled=$wifi_now"
[ "$wifi_now" = 1 ] || { log 'FAIL wifi_readback'; ok=0; }

if [ "$ok" = 1 ]; then echo restored > "$STATE"; else echo restore_failed > "$STATE"; fi
log "=== restore done ok=$ok ==="
[ "$ok" = 1 ] || exit 90
