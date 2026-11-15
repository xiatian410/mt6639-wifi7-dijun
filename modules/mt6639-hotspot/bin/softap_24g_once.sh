#!/system/bin/sh
# One-shot C02 acceptance: keep LabNet-6G STA and start HE-only 2.4GHz AP.
set -u
umask 077
MODDIR=${1:-}
case "$MODDIR" in /data/adb/modules/mt6639-hotspot) ;; *) exit 64 ;; esac
[ -d "$MODDIR" ] && [ ! -L "$MODDIR" ] || exit 66
[ "$(id -u)" = 0 ] && [ "$(id -Z)" = u:r:ksu:s0 ] || exit 77
[ "$(getenforce)" = Enforcing ] || exit 77

WORK=/data/adb/mt6639-hotspot
PRIVATE=$WORK/private
STATE=$WORK/c02-24g
[ -d "$WORK" ] && [ ! -L "$WORK" ] && [ "$(stat -c %a "$WORK")" = 700 ] || exit 66
[ -d "$PRIVATE" ] && [ ! -L "$PRIVATE" ] && [ "$(stat -c %a "$PRIVATE")" = 700 ] || exit 66
[ ! -e "$MODDIR/disable" ] && [ ! -e "$MODDIR/remove" ] || exit 73
sh "$MODDIR/bin/verify-module.sh" "$MODDIR" || exit 69

key=$PRIVATE/reconnect.key
[ -f "$key" ] && [ ! -L "$key" ] && [ "$(stat -c %u "$key")" = 0 ] &&
    [ "$(stat -c %a "$key")" = 600 ] && [ -s "$key" ] || exit 66

# C02 is not allowed to run beside the native mtap0 session.
[ ! -e "$WORK/session/task" ] || { echo 'REJECT native_session_exists' >&2; exit 73; }
[ ! -e /sys/class/net/mtap0 ] || { echo 'REJECT mtap0_exists' >&2; exit 73; }
timeout 5 dumpsys tethering --short 2>/dev/null |
    grep -Fxq '    Upstream wanted: false' ||
    { echo 'REJECT tethering_not_idle' >&2; exit 73; }

[ ! -L "$STATE" ] && { [ ! -e "$STATE" ] || [ -d "$STATE" ]; } || exit 73
[ -d "$STATE" ] || mkdir "$STATE" || exit 70
chmod 0700 "$STATE" || exit 70

boot=$(cat /proc/sys/kernel/random/boot_id) || exit 70
task=$(mktemp -d "/data/local/tmp/mt6639-ap-c02-${boot%%-*}-XXXXXX") || exit 70
chmod 0700 "$task" || exit 70
for file in softap_once.sh softap_profile.sh softap-profile.dex twt_recover.sh; do
    cp "$MODDIR/bin/$file" "$task/$file" || {
        echo "REJECT stage_failed $file" >&2
        exit 70
    }
done
cp "$key" "$task/reconnect.key" || exit 70
chmod 0755 "$task/softap_once.sh" "$task/softap_profile.sh" "$task/twt_recover.sh"
chmod 0644 "$task/softap-profile.dex"
chmod 0600 "$task/reconnect.key"

printf '%s\n' "$task" > "$STATE/last-task.tmp" &&
    mv "$STATE/last-task.tmp" "$STATE/last-task" || exit 70
printf '%s\n' "$boot" > "$STATE/boot" || exit 70
started=$(date '+%Y-%m-%d %H:%M:%S') || exit 70
printf '%s\n' "$started" > "$STATE/started" || exit 70

timeout -s KILL 180 sh "$task/softap_once.sh" "$task" run-24g > "$task/job.log" 2>&1
rc=$?
finished=$(date '+%Y-%m-%d %H:%M:%S') || finished=unknown
printf '%s\n' "$rc" > "$STATE/rc.tmp" && mv "$STATE/rc.tmp" "$STATE/rc" || exit 70
printf '%s\n' "$finished" > "$STATE/finished" || exit 70
cat "$task/job.log"
if [ "$rc" = 0 ] && grep -q '^RESULT=trial_finished mode=run-24g' "$task/job.log" &&
    [ "$(cat "$task/action.rc" 2>/dev/null)" = 0 ] &&
    [ "$(cat "$task/recovery.rc" 2>/dev/null)" = 0 ]; then
    echo "C02_RESULT=verified_candidate task=$task"
    exit 0
fi
echo "C02_RESULT=failed rc=$rc task=$task" >&2
exit "${rc:-71}"
