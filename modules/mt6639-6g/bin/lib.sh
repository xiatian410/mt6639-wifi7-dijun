#!/system/bin/sh
# 共用工具：路径、哈希、版本锁、日志。
# 只允许操作本模块自有目录与 /odm/firmware/wifi.cfg 的临时 bind 覆盖。

MODDIR=${MODDIR:-/data/adb/modules/mt6639-6g}
. "$MODDIR/bin/owner.sh"
WORK=${WORK:-/data/adb/mt6639-6g}
LOG=${LOG:-$WORK/apply.log}
STATE=${STATE:-$WORK/state}

# 路径与哈希在测试模式下才允许覆盖，生产路径写死，避免配置错误指向别的文件。
if [ "${MT6639_TEST_MODE:-0}" = 1 ]; then
    COMPAT_PROFILE=fixture
    COMPAT_ERROR=
    CFG=${CFG:?test mode requires CFG}
    STOCK_CFG_SHA=${STOCK_CFG_SHA:?test mode requires STOCK_CFG_SHA}
    STOCK_KO=${STOCK_KO:?test mode requires STOCK_KO}
    STOCK_KO_SHA=${STOCK_KO_SHA:?test mode requires STOCK_KO_SHA}
    KERNEL_GUARD=${KERNEL_GUARD:-$(uname -r)}
else
    CFG=/odm/firmware/wifi.cfg
    STOCK_KO=/vendor/lib/modules/wlan_drv_gen4m_eap_6639.ko
    # Modern vendor_dlkm mount layouts need not expose the old vendor alias.
    # Never hide a differing existing vendor file by silently trying another.
    if [ ! -e "$STOCK_KO" ] && [ ! -L "$STOCK_KO" ]; then
        STOCK_KO=/vendor_dlkm/lib/modules/wlan_drv_gen4m_eap_6639.ko
    fi
    . "$MODDIR/bin/compat.sh"
fi
BOOT_ID_FILE=${BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}
MOUNTINFO_FILE=${MOUNTINFO_FILE:-/proc/self/mountinfo}
INIT_MOUNTINFO_FILE=${INIT_MOUNTINFO_FILE:-/proc/1/mountinfo}
INIT_CFG_PATH=${INIT_CFG_PATH:-/proc/1/root/odm/firmware/wifi.cfg}
BOOT_GUARD_FILE=$WORK/boot_id
SCAN_GUARD_FILE=$WORK/scan_before
ACTIVE_TX_FILE=$WORK/active_tx
ACTIVE_PID_FILE=$WORK/active_pid

if [ "${MT6639_TEST_MODE:-0}" = 1 ] && [ -n "${NATIVE:-}" ]; then
    :
else
    NATIVE=$MODDIR/bin/mount-txn
fi

# This runs before log/lock/state creation in every entrypoint. A permissive
# inherited umask or an older installation must not leave a writable ancestor
# that the native directory() walk will reject before creating its journal.
prepare_work_directory() {
    [ ! -L "$WORK" ] || return 1
    (umask 077; mkdir -p -m 0700 "$WORK") 2>/dev/null || return 1
    [ -d "$WORK" ] && [ ! -L "$WORK" ] || return 1
    work_owner=$(stat -c %u "$WORK" 2>/dev/null) || return 1
    if [ "${MT6639_TEST_MODE:-0}" = 1 ]; then
        # Host fixtures may run without root; still require their own owner.
        expected_owner=$(stat -c %u "$MODDIR" 2>/dev/null) || return 1
    else
        expected_owner=0
    fi
    [ "$work_owner" = "$expected_owner" ] || return 1
    chmod 0700 "$WORK" 2>/dev/null || return 1
    [ ! -L "$WORK" ] &&
        [ "$(stat -c '%u:%a' "$WORK" 2>/dev/null)" = "$expected_owner:700" ]
}
prepare_work_directory || {
    echo 'REJECT work_directory_not_private' >&2
    exit 3
}

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log() {
    echo "[$(ts)] $*" >>"$LOG" 2>/dev/null
    echo "[$(ts)] $*"
}

file_sha() { sha256sum "$1" 2>/dev/null | cut -d ' ' -f 1; }

if [ "${MT6639_TEST_MODE:-0}" != 1 ]; then
    select_runtime_profile "$(uname -r)" "$MODDIR/compatibility.conf" "$(file_sha "$STOCK_KO")" || :
fi

# root 在 u:r:ksu:s0 域里直接调 cmd wifi / settings 会 can't find service，
# 必须切回 shell 域执行 Binder 调用。
sh_shell() { timeout 20 runcon u:r:shell:s0 sh -c "$1" 2>&1; }

# Do not pipe the reader into tr: that hides failure/timeout after valid text.
read_setting() {
    setting_raw=$(sh_shell "settings get global $1") || return 1
    printf '%s\n' "$setting_raw" | tr -d '\r'
}

# runcon 直接 exec 非 shell 二进制会被拒，必须经 sh -c 包裹。
wifi() {
    quoted=
    for a in "$@"; do
        quoted="$quoted '$a'"
    done
    timeout 20 runcon u:r:shell:s0 sh -c "cmd wifi $quoted" 2>&1
}

boot_id() { cat "$BOOT_ID_FILE" 2>/dev/null; }

# Best-effort runtime restoration, but never report success if any command
# failed. Scan must stay disabled throughout teardown (see real T05 evidence).
restore_wifi_cycle() {
    case "$1" in 0|1) ;; *) log 'FAIL invalid_scan_baseline'; return 1 ;; esac
    cycle_ok=1
    wifi set-scan-always-available disabled >/dev/null 2>&1 || { log 'FAIL scan_off'; cycle_ok=0; }
    wifi set-wifi-enabled disabled >/dev/null 2>&1 || { log 'FAIL wifi_off'; cycle_ok=0; }
    sleep 8
    wifi set-wifi-enabled enabled >/dev/null 2>&1 || { log 'FAIL wifi_on'; cycle_ok=0; }
    sleep 12
    sh_shell "settings put global wifi_scan_always_enabled $1" >/dev/null 2>&1 || { log 'FAIL scan_restore'; cycle_ok=0; }
    [ "$cycle_ok" = 1 ]
}

# 四项版本锁：boot 只在 apply 时绑定，不跨 boot 复用。
require_identity() {
    [ "$(id -u)" = 0 ] || { log "REJECT not_root"; return 3; }
    [ -z "$COMPAT_ERROR" ] || {
        log "REJECT $COMPAT_ERROR $(uname -r)"; return 3; }
    [ "$(uname -r)" = "$KERNEL_GUARD" ] || {
        log "REJECT kernel_mismatch $(uname -r)"; return 3; }
    [ "$(file_sha "$CFG")" = "$STOCK_CFG_SHA" ] || {
        log "REJECT cfg_not_stock $(file_sha "$CFG")"; return 3; }
    [ "$(file_sha "$STOCK_KO")" = "$STOCK_KO_SHA" ] || {
        log "REJECT ko_not_stock $(file_sha "$STOCK_KO")"; return 3; }
    return 0
}

# 目标目录里是否已经有人挂了东西：绝不叠加。
require_unmounted() {
    # Read separately: a failed procfs read must never mean "not mounted".
    mountinfo=$(cat "${1:-$MOUNTINFO_FILE}" 2>/dev/null) || {
        log 'REJECT mountinfo_unreadable'; return 3; }
    printf '%s\n' "$mountinfo" | awk -v target="$CFG" '
        $5 == target { found=1 } END { exit(found ? 0 : 1) }'
    mount_rc=$?
    case "$mount_rc" in
        1) return 0 ;;
        0) log 'REJECT cfg_already_mounted' ;;
        *) log 'REJECT mountinfo_check_failed' ;;
    esac
    return 3
}
