#!/system/bin/sh
# 启用 6GHz 实验。生产原生入口默认持续，可显式 bounded 或提前 restore。
# 任何一步失败都走 restore 路径，并把结果如实写进日志。
set -u
MODDIR=${1:-${MODDIR:-/data/adb/modules/mt6639-6g}}
. "$MODDIR/bin/owner.sh"
require_owner_mutation || exit 3
if [ "$MODULE_EMBEDDED" = 1 ]; then require_owner_enabled || exit 3; fi
. "$MODDIR/bin/lib.sh"
[ -f "$MODDIR/config.conf" ] && . "$MODDIR/config.conf"

ENABLE_6G=${ENABLE_6G:-0}

if [ "${NATIVE_EXECUTOR:-1}" = 1 ]; then
    if [ "$ENABLE_6G" != 1 ]; then
        log "apply skipped: ENABLE_6G=$ENABLE_6G"
        exit 0
    fi
    exec sh "$MODDIR/bin/control.sh" "$MODDIR" enable
fi

if [ "$ENABLE_6G" != 1 ]; then
    log "apply skipped: ENABLE_6G=$ENABLE_6G (default off)"
    exit 0
fi

log "=== apply start boot=$(boot_id | cut -c1-8) ==="
require_identity || exit 3
require_unmounted || exit 3

mkdir -p "$WORK"
cp "$CFG" "$WORK/wifi.cfg.stock" 2>/dev/null || { log "FAIL backup_cfg"; exit 3; }
[ "$(file_sha "$WORK/wifi.cfg.stock")" = "$STOCK_CFG_SHA" ] || { log "FAIL backup_cfg_hash"; exit 3; }

CAND=$WORK/wifi-6g.cfg
sed 's/^DisallowBand6G 1$/DisallowBand6G 0/' "$WORK/wifi.cfg.stock" > "$CAND" || {
    log "FAIL write_candidate"; exit 3; }

diff "$WORK/wifi.cfg.stock" "$CAND" > "$WORK/candidate.diff" 2>&1
# Verify the change precisely without relying on diff line syntax (toybox awk
# and grep -c behave differently from GNU/BSD). Requirements:
#   1. identical line counts, so nothing was added or removed
#   2. exactly one "DisallowBand6G 1" in stock, zero in candidate
#   3. exactly one "DisallowBand6G 0" in candidate, zero in stock
lines_stock=$(wc -l < "$WORK/wifi.cfg.stock" | tr -d ' ')
lines_cand=$(wc -l < "$CAND" | tr -d ' ')
old_stock=$(grep -c '^DisallowBand6G 1$' "$WORK/wifi.cfg.stock" || true)
old_cand=$(grep -c '^DisallowBand6G 1$' "$CAND" || true)
new_stock=$(grep -c '^DisallowBand6G 0$' "$WORK/wifi.cfg.stock" || true)
new_cand=$(grep -c '^DisallowBand6G 0$' "$CAND" || true)
if [ "$lines_stock" != "$lines_cand" ] || [ "$old_stock" != 1 ] || \
   [ "$old_cand" != 0 ] || [ "$new_stock" != 0 ] || [ "$new_cand" != 1 ]; then
    log "REJECT candidate_check lines=$lines_stock/$lines_cand old=$old_stock/$old_cand new=$new_stock/$new_cand"
    exit 3
fi
log "candidate verified: single-line flip, line count unchanged ($lines_stock)"

chmod 0644 "$CAND"
chcon u:object_r:wlan_fwfile:s0 "$CAND" 2>/dev/null || { log "FAIL chcon"; exit 3; }

# 只在挂载前记录 boot，restore 时据此判断是否跨 boot。
boot_id > "$BOOT_GUARD_FILE"

scan_was=$(read_setting wifi_scan_always_enabled) || { log 'REJECT failed_scan_baseline'; exit 3; }
case "$scan_was" in 0|1) ;; *) log 'REJECT unknown_scan_baseline'; exit 3 ;; esac
wifi_was=$(read_setting wifi_on) || { log 'REJECT failed_wifi_baseline'; exit 3; }
[ "$wifi_was" = 1 ] || { log 'REJECT wifi_must_be_enabled'; exit 3; }
echo "$scan_was" > "$SCAN_GUARD_FILE" || { log 'FAIL save_scan_baseline'; exit 3; }
echo "scan_was=$scan_was" > "$STATE"

rollback() {
    rc=$?
    trap - EXIT HUP INT TERM
    log "rollback begin rc=$rc"
    WORK="$WORK" sh "$MODDIR/bin/restore.sh" "$MODDIR"
    rollback_rc=$?
    log "rollback cfg_sha=$(file_sha "$CFG")"
    log "=== apply aborted ==="
    [ "$rollback_rc" = 0 ] || exit 90
    [ "$rc" != 0 ] || rc=3
    exit "$rc"
}
trap rollback EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mount --bind "$CAND" "$CFG" || { log "FAIL bind"; exit 3; }
[ "$(file_sha "$INIT_CFG_PATH")" = "$(file_sha "$CAND")" ] || {
    log "FAIL bind_not_visible_to_init"; exit 3; }
log "bind ok candidate_sha=$(file_sha "$CAND")"

# 正常关闭/开启 Wi-Fi，让原厂驱动重建并重读配置；不卸载驱动、不 PCI rebind。
wifi set-scan-always-available disabled >/dev/null 2>&1 || { log 'FAIL scan_off'; exit 3; }
wifi set-wifi-enabled disabled >/dev/null 2>&1 || { log 'FAIL wifi_off'; exit 3; }
sleep 8
wifi set-wifi-enabled enabled >/dev/null 2>&1 || { log 'FAIL wifi_on'; exit 3; }
sleep 12

if [ -x "$WORK/nl80211-wiphy-read" ]; then
    if "$WORK/nl80211-wiphy-read" > "$WORK/wiphy-after.txt" 2>&1; then
        six=$(grep -c '^frequency band_enum=3 ' "$WORK/wiphy-after.txt" 2>/dev/null)
        log "wiphy_dump ok 6g_lines=${six:-0}"
    else
        log "wiphy_dump FAILED (not treated as absence)"
    fi
fi

trap - EXIT HUP INT TERM
echo active > "$STATE"
log "=== apply done (state=active) ==="
