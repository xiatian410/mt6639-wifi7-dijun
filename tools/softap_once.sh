#!/system/bin/sh
# One short BSS observation. No throughput/compatibility matrix or tethering claim.
set -u
umask 077
D=${1:-} OP=${2:-}
case "$D" in /data/local/tmp/mt6639-ap-*) ;; *) exit 64 ;; esac
[ -d "$D" ] && [ ! -L "$D" ] && [ "$(stat -c %u "$D")" = 0 ] &&
    [ "$(stat -c %a "$D")" = 700 ] && [ "$(id -Z)" = u:r:ksu:s0 ] &&
    [ "$(getenforce)" = Enforcing ] || exit 77
SELF=$D/softap_once.sh
SIX=/data/adb/modules/mt6639-hotspot/six
profile() { sh "$D/softap_profile.sh" "$D" "$@"; }
java() { CLASSPATH="$D/softap-profile.dex" timeout -k 2 12 app_process /system/bin WifiSoftApProfile "$@"; }
boot_ok() { [ "$(cat /proc/sys/kernel/random/boot_id)" = "$(cat "$D/boot.before")" ]; }
recover() {
    exec 9>"$D/trial-recover.lock"
    flock -x 9 9>&9 || return 70
    [ ! -f "$D/recovery.rc" ] || return "$(cat "$D/recovery.rc")"
    boot_ok || { echo boot_changed >&2; return 78; }
    rc=0
    if [ -f "$D/start.intent" ]; then
        java stop "$D" > "$D/ap.stop" 2>&1 || rc=1
        n=0
        while [ "$n" -lt 12 ]; do
            java inspect > "$D/ap.stopping" 2>&1 || break
            grep -qx 'ap_state=11' "$D/ap.stopping" && break
            sleep 1; n=$((n+1))
        done
    fi
    profile restore > "$D/profile.restore" 2>&1 || rc=1
    mkdir "$D/network-recover" || rc=1
    if [ -d "$D/network-recover" ]; then
        cp "$D/reconnect.key" "$D/network-recover/reconnect.key" || rc=1
        sh "$D/twt_recover.sh" check "$D/network-recover" "$(cat "$D/boot.before")" LabNet-6G 6135 02:00:00:00:73:1c 198.51.100.242 "$SIX/bin/post-reboot-check.sh" "$SIX" > "$D/network.check" 2>&1
        if [ "$?" != 0 ]; then
            mkdir "$D/network-select" || rc=1
            cp "$D/reconnect.key" "$D/network-select/reconnect.key" || rc=1
            sh "$D/twt_recover.sh" select "$D/network-select" "$(cat "$D/boot.before")" LabNet-6G 6135 02:00:00:00:73:1c 198.51.100.242 "$SIX/bin/post-reboot-check.sh" "$SIX" > "$D/network.select" 2>&1 || rc=1
        fi
    fi
    printf '%s\n' "$rc" > "$D/recovery.rc"
    : > "$D/guardian.done"
    return "$rc"
}
case "$OP" in
    guardian)
        echo "$$" > "$D/guardian.pid"
        : > "$D/guardian.ready"
        n=0
        while [ "$n" -lt 90 ] && [ ! -f "$D/cleanup.request" ]; do sleep 1; n=$((n+1)); done
        recover; exit $? ;;
    recover) recover; exit $? ;;
    run|run-24g|run-5g) ;;
    *) exit 64 ;;
esac
# Setup must not bypass the unified owner's reboot/legacy-module barrier.
sh /data/adb/modules/mt6639-hotspot/bin/unified-guard.sh \
    /data/adb/modules/mt6639-hotspot check || exit $?
exec 8>"$D/owner.lock"
flock -n 8 8>&8 || exit 75
(set -C; : > "$D/trial.claimed") 2>/dev/null || exit 73
[ -s "$D/reconnect.key" ] && [ ! -L "$D/reconnect.key" ] || exit 66
case "$OP" in
    run-24g)
        profile_mode=enable-24g
        expected_band=2.4GHz
        expected_standard=6
        ;;
    run|run-5g)
        profile_mode=enable-5g
        expected_band=5GHz
        expected_standard=8
        ;;
    *) exit 64 ;;
esac
profile inspect > "$D/profile.before" 2>&1 || exit 69
grep -qx 'ap_state=11' "$D/profile.before" || exit 75
cat /proc/sys/kernel/random/boot_id > "$D/boot.before" || exit 74
cmd wifi status > "$D/sta.before" 2>&1 || exit 69
grep -Fxq 'Wifi is connected to "LabNet-6G"' "$D/sta.before" || exit 69
iw dev wlan0 link > "$D/link.before" 2>&1 || exit 69
mkdir "$D/backup" || exit 73
for file in /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml /odm/firmware/wifi.cfg; do
    cp -p "$file" "$D/backup/$(basename "$file")" || exit 74
    original=$(sha256sum "$file" | cut -d ' ' -f 1)
    saved=$(sha256sum "$D/backup/$(basename "$file")" | cut -d ' ' -f 1)
    [ "$original" = "$saved" ] || exit 74
    echo "$original $file" >> "$D/backup/SHA256-before.txt"
done
sha256sum "$SELF" "$D/softap_profile.sh" "$D/softap-profile.dex" "$D/twt_recover.sh" >> "$D/backup/SHA256-before.txt" || exit 74
nohup sh "$SELF" "$D" guardian > "$D/guardian.log" 2>&1 8>&8 < /dev/null &
guard=$!
n=0
while [ ! -f "$D/guardian.ready" ] && [ "$n" -lt 5 ]; do sleep 1; n=$((n+1)); done
[ -f "$D/guardian.ready" ] && kill -0 "$guard" || exit 70
trap ': > "$D/cleanup.request"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
exec 9>"$D/trial-recover.lock"
flock -x 9 9>&9 || exit 75
boot_ok && kill -0 "$guard" && [ ! -f "$D/recovery.rc" ] || exit 78
action_rc=0
if profile "$profile_mode" > "$D/profile.enable" 2>&1; then
    : > "$D/start.intent"
    java start "$D" > "$D/ap.start" 2>&1 || action_rc=1
else action_rc=1; fi
flock -u 9 9>&9
exec 9>&-
if [ "$action_rc" = 0 ]; then
    sleep 8
    profile inspect > "$D/profile.active" 2>&1 || action_rc=1
    iw dev > "$D/interfaces.active" 2>&1
    timeout 8 dumpsys wifi > "$D/wifi.active" 2>&1
    timeout 6 logcat -b all -d -v epoch -t 1200 > "$D/logcat.active" 2>&1
    mkdir "$D/hostapd-config" || action_rc=1
    for conf in /data/vendor/wifi/hostapd/hostapd_ap0*.conf; do
        [ ! -f "$conf" ] || cp -p "$conf" "$D/hostapd-config/" || action_rc=1
    done
    # The enabled state and accepted request do not prove the requested band/EHT.
    info=$(grep '^mCurrentSoftApInfoMap {ap0=SoftApInfo{' "$D/wifi.active" | head -n 1)
    frequency=$(printf '%s\n' "$info" | sed -n 's/.*frequency= *\([0-9][0-9]*\),.*/\1/p')
    standard=$(printf '%s\n' "$info" | sed -n 's/.*wifiStandard= *\([0-9][0-9]*\),.*/\1/p')
    printf 'frequency=%s\nstandard=%s\nexpected_band=%s\nexpected_standard=%s\n' \
        "$frequency" "$standard" "$expected_band" "$expected_standard" > "$D/bss.observed"
    if [ "$OP" = run-24g ]; then
        case "$frequency" in 2[0-5][0-9][0-9]) ;; *) action_rc=1 ;; esac
    else
        case "$frequency" in 5[0-8][0-9][0-9]) ;; *) action_rc=1 ;; esac
    fi
    [ "$standard" = "$expected_standard" ] || action_rc=1
    grep -qx 'ap_state=13' "$D/profile.active" || action_rc=1
fi
printf '%s\n' "$action_rc" > "$D/action.rc"
: > "$D/cleanup.request"
wait "$guard"
guard_rc=$?
[ "$action_rc" = 0 ] && [ "$guard_rc" = 0 ] && [ "$(cat "$D/recovery.rc")" = 0 ] || exit 71
echo "RESULT=trial_finished mode=$OP expected_band=$expected_band expected_standard=$expected_standard BSS_evidence_requires_review"
