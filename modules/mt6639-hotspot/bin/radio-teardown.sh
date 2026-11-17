#!/system/bin/sh
# Fixed native recovery barrier. Never acquires the six/radio locks or calls six.
# Native guardian/explicit recovery owns its transaction lock during this call.
set -u
MODDIR=/data/adb/modules/mt6639-hotspot
[ "$#" -le 1 ] || exit 64
OP=${1:-stop}
case "$OP" in stop|check) ;; *) exit 64 ;; esac
[ "$(id -u)" = 0 ] && [ "$(id -Z)" = u:r:ksu:s0 ] || exit 77
[ -d "$MODDIR" ] && [ ! -L "$MODDIR" ] || exit 66
# No migration/enable gate: disable/remove must still be able to tear down.
# A missing/modified installed module is NOT permission to restart WLAN blindly.
sh "$MODDIR/bin/verify-module.sh" "$MODDIR" || exit 69
if [ "$OP" = stop ]; then
    stop_output=$(timeout 360 sh "$MODDIR/bin/control.sh" "$MODDIR" stop 7>&- 8>&- 9>&- 2>&1)
    rc=$?
    printf '%s\n' "$stop_output"
    [ "$rc" = 0 ] || exit "$rc"
    lock=/data/adb/mt6639-hotspot/action.lock
    [ -f "$lock" ] && [ ! -L "$lock" ] && [ "$(stat -c %u "$lock")" = 0 ] || exit 73
    exec 7>>"$lock" || exit 74
    flock -w 3 7 || exit 75
fi
# For check, the native caller holds action.lock across this check AND recovery.
# The helper remains read-only and cannot itself authorize recovery.
out=$(timeout 30 sh "$MODDIR/bin/control.sh" "$MODDIR" status 7>&- 8>&- 9>&- 2>&1)
rc=$?
printf '%s\n' "$out"
[ "$rc" = 0 ] || exit "$rc"
state=$(printf '%s\n' "$out" | sed -n 's/^state=\([^ ]*\).*/\1/p' | head -1)
[ "$state" = idle ] || exit 73
exit 0
