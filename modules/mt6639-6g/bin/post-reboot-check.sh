#!/system/bin/sh
# Read-only snapshot check. A pass alone does not prove a reboot occurred.
set -u
MODE=${1:-active}
case "$MODE" in active|restored) ;; *) echo 'usage: post-reboot-check.sh [active|restored] [embedded-six-path]'; exit 64 ;; esac
[ "$#" -le 2 ] || exit 64
if [ "${MT6639_TEST_MODE:-0}" = 1 ]; then
    MODDIR=${2:-${MODDIR:?test mode requires MODDIR}}
else
    MODDIR=/data/adb/modules/mt6639-6g
    case "${2:-}" in
        '') ;;
        /data/adb/modules/mt6639-hotspot/six) MODDIR=$2 ;;
        *) echo 'REJECT invalid_six_path' >&2; exit 64 ;;
    esac
fi
. "$MODDIR/bin/lib.sh"
KO=$STOCK_KO
CFG_SHA=$STOCK_CFG_SHA
KO_SHA=$STOCK_KO_SHA
fail=0
say() { echo "$*"; }
bad() { echo "FAIL $*"; fail=$((fail+1)); }

boot=$(boot_id)
boot8=$(printf '%s' "$boot" | cut -c1-8)
say "boot=$boot"
say "compatibility_profile=$COMPAT_PROFILE"
[ -z "$COMPAT_ERROR" ] || bad "$COMPAT_ERROR"
[ "$(uname -r)" = "$KERNEL_GUARD" ] || bad kernel_mismatch

[ "$(id -u)" = 0 ] && say "root=uid0" || bad "root_uid_not_0"
ctx=$(cat /proc/self/attr/current 2>/dev/null | tr -d '\000') || true
say "selinux_context=$ctx"
[ "$(getenforce 2>/dev/null)" = Enforcing ] && say "selinux=enforcing" || bad "selinux_not_enforcing"

if [ -d "$MODDIR" ]; then
    say "active_module_path=$MODDIR"
else
    bad "module_not_active_path"
fi
if [ -f "$MODULE_OWNER/module.prop" ]; then
    ver=$(grep '^version=' "$MODULE_OWNER/module.prop" | cut -d= -f2-)
    say "module_version=$ver"
    # Never pin a literal version here: this checker is also consumed by the
    # hotspot module as its station checker, so a version bump in the 6GHz module
    # used to make every hotspot teardown report recovery_rc=1. Verify the module
    # tree against its own SHA256SUMS instead — it is stronger and version-agnostic.
    [ -f "$MODULE_OWNER/SHA256SUMS" ] || bad "module_sums_missing"
    if [ -f "$MODULE_OWNER/SHA256SUMS" ]; then
        sh "$MODDIR/bin/verify-module.sh" "$MODDIR" ||
            bad "module_sums_mismatch"
    fi
else
    bad "module_prop_missing"
fi

cfg=$(sha256sum "$CFG" 2>/dev/null | cut -d' ' -f1)
ko=$(sha256sum "$KO" 2>/dev/null | cut -d' ' -f1)
say "cfg_sha=$cfg"
say "ko_sha=$ko"
[ "$ko" = "$KO_SHA" ] || bad "ko_not_stock"

if [ "$MODE" = active ]; then
    backup=$WORK/backup-$boot/wifi.cfg.stock
    [ "$(sha256sum "$backup" 2>/dev/null | cut -d' ' -f1)" = "$CFG_SHA" ] || bad "backup_not_stock"
    expected=$(sed 's/^DisallowBand6G 1$/DisallowBand6G 0/' "$backup" 2>/dev/null | sha256sum | cut -d' ' -f1)
    [ "$cfg" = "$expected" ] || bad "cfg_not_expected_candidate"
    grep -q " $CFG " "$MOUNTINFO_FILE" 2>/dev/null || bad "cfg_mount_missing"
    require_owner_enabled || bad "module_disabled_or_removing"
    runtime=$(sh "$MODDIR/bin/native.sh" "$MODDIR" status) || bad "native_status_failed"
    say "$runtime"
    printf '%s\n' "$runtime" | grep -qx 'guardian=alive' || bad "guardian_not_alive"
    printf '%s\n' "$runtime" | grep -qx 'state=active' || bad "state_not_active"
    tx=$(cat "$WORK/active_tx" 2>/dev/null)
    [ "$(cat "$tx/wrapper-boot" 2>/dev/null)" = "$boot" ] || bad "transaction_boot_mismatch"
    grep -q '"event":"persistent-hold"' "$tx/guardian.log" 2>/dev/null || bad "persistent_hold_not_observed"
else
    [ "$cfg" = "$CFG_SHA" ] || bad "cfg_not_stock"
    grep -q " $CFG " "$MOUNTINFO_FILE" 2>/dev/null
    case "$?" in 0) bad "cfg_still_mounted" ;; 1) say "cfg_mount=none" ;; *) bad "mountinfo_unreadable" ;; esac
    runtime=$(sh "$MODDIR/bin/native.sh" "$MODDIR" status) || bad "native_status_failed"
    say "$runtime"
    printf '%s\n' "$runtime" | grep -qx 'active_tx=none' || bad "active_transaction_present_or_invalid"
fi

enabled=$(grep '^ENABLE_6G=' "$MODDIR/config.conf" 2>/dev/null | head -1)
say "config=$enabled"
case "$enabled" in
    'ENABLE_6G=${ENABLE_6G:-1}') ;;
    *) bad "default_on_config_mismatch" ;;
esac
grep -qx 'RUN_MODE=${RUN_MODE:-persistent}' "$MODDIR/config.conf" || bad "default_persistent_config_mismatch"

if grep -q "service: boot=$boot8 ENABLE_6G=1" "$WORK/apply.log" 2>/dev/null; then
    say "service_default_on=observed_this_boot"
else
    bad "service_default_on_not_observed"
fi

if [ -x "$MODDIR/bin/mount-txn" ] || [ -f "$MODDIR/bin/mount-txn" ]; then
    native_info=$(sh "$MODDIR/bin/native.sh" "$MODDIR" inspect 2>&1) || bad "native_inspect_failed"
    echo "$native_info"
    if [ "$MODE" = active ]; then country=US; else country=CN; fi
    printf '%s\n' "$native_info" | grep -q "\"country_code\":\"$country\"" && say "country=$country" || bad "country_unexpected"
else
    bad "native_binary_missing"
fi

echo "RESULT fail=$fail"
[ "$fail" = 0 ]
