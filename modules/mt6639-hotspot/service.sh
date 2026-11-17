#!/system/bin/sh
# Unified boot owner: no independent six service or soft-reboot watchdog.
set -u
MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/mt6639-hotspot
[ "$(id -u)" = 0 ] && [ "$(id -Z)" = u:r:ksu:s0 ] || exit 77
[ ! -L "$MODDIR" ] || exit 77
sh "$MODDIR/bin/verify-module.sh" "$MODDIR" || exit $?
sh "$MODDIR/bin/unified-guard.sh" "$MODDIR" check || exit $?
[ ! -e "$MODDIR/disable" ] && [ ! -e "$MODDIR/remove" ] || exit 73
. "$MODDIR/config.conf"
# Publish a current-boot read-only snapshot even when automatic start is off.
sh "$MODDIR/bin/status_snapshot.sh" "$MODDIR" init >/dev/null 2>&1 || exit $?
if [ "${ENABLE_SETTINGS_BRIDGE:-1}" = 1 ]; then
    sh "$MODDIR/bin/request_worker.sh" "$MODDIR" start >/dev/null 2>&1 || {
        echo "mt6639-hotspot: settings bridge failed to start" >&2; exit 70; }
fi
if [ "${ENABLE_AT_BOOT:-0}" != 1 ]; then
    echo "mt6639-hotspot: ENABLE_AT_BOOT=0; manual six-on/start required"
    exit 0
fi
# Only the default 6GHz combined profile is supported for boot autostart.
[ "${BAND:-6g}" = 6g ] || { echo 'REJECT unified_autostart_requires_6g' >&2; exit 64; }
exec sh "$MODDIR/bin/radio-control.sh" "$MODDIR" start "${WIDTH:-20}"
