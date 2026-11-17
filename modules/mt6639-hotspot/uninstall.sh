#!/system/bin/sh
# Keep all transaction/session journals for checked retry and offline review.
set -u
MODDIR=${0%/*}
[ -d "$MODDIR" ] || MODDIR=/data/adb/modules/mt6639-hotspot
[ "$(id -u)" = 0 ] && [ "$(id -Z)" = u:r:ksu:s0 ] || exit 77
[ ! -L "$MODDIR" ] || exit 77
sh "$MODDIR/bin/request_worker.sh" "$MODDIR" stop || {
    echo 'REJECT uninstall_worker_stop_failed; journals preserved' >&2; exit 70; }
sh "$MODDIR/bin/radio-teardown.sh" stop || {
    echo 'REJECT uninstall_hotspot_stop_failed; journals preserved' >&2; exit 70; }
timeout 1320 sh "$MODDIR/six/bin/control.sh" "$MODDIR/six" disable || {
    echo 'REJECT uninstall_six_restore_failed; journals preserved' >&2; exit 70; }
echo 'mt6639-hotspot: checked AP stop and six restore completed; journals preserved'
