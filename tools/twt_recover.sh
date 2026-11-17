#!/system/bin/sh
# Recovery/verification only: never sends TWT, cycles Wi-Fi, or loads modules.
# check|select TASK BOOT SSID FREQ BSSID PEER CHECKER [SIX]
# TASK is a fresh root-private directory; select reads TASK/reconnect.key.
set -u
umask 077
[ "$#" -eq 8 ] || [ "$#" -eq 9 ] || exit 64
MODE=$1 D=$2 BOOT=$3 SSID=$4 FREQ=$5 BSSID=$6 PEER=$7 CHECKER=$8
SIX=${9:-}
case "$SIX" in ''|/data/adb/modules/mt6639-hotspot/six) ;; *) exit 64 ;; esac
if [ -n "$SIX" ]; then
    [ "$CHECKER" = "$SIX/bin/post-reboot-check.sh" ] || exit 64
fi
case "$MODE" in check|select) ;; *) exit 64 ;; esac
case "$D" in /*) ;; *) exit 64 ;; esac
[ -d "$D" ] && [ ! -L "$D" ] && [ -f "$CHECKER" ] || exit 64
case "$FREQ" in ''|*[!0-9]*) exit 64 ;; esac
case "$PEER" in ''|*[!0-9.]*) exit 64 ;; esac
printf '%s\n' "$BSSID" | grep -Eq '^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$' || exit 64
[ "$(id -u)" = 0 ] || exit 77
V=$D/verification
# Atomic ownership; do not overwrite an earlier result or resume stale evidence.
mkdir "$V" || exit 73
terminal=0
log() { printf '%s %s\n' "$(date +%s)" "$*" >> "$V/stages.txt"; }
finish() {
    status=$1 stage=$2 code=$3
    printf 'status=%s\nstage=%s\nrc=%s\n' "$status" "$stage" "$code" > "$V/result.tmp" &&
        mv "$V/result.tmp" "$V/result.txt" || exit 74
    if [ "$status" = recovered ]; then
        : > "$V/recovered" || exit 74
    fi
    terminal=1
    trap - EXIT
    printf 'RESULT %s stage=%s rc=%s\n' "$status" "$stage" "$code"
    exit "$code"
}
unexpected() {
    rc=$?
    [ "$rc" -ne 0 ] || rc=70
    [ "$terminal" = 1 ] || finish failed unexpected_exit "$rc"
}
trap unexpected EXIT
fail() { finish failed "$1" "${2:-1}"; }
boot_ok() {
    current=$(timeout 3 cat /proc/sys/kernel/random/boot_id) || return 1
    [ "$current" = "$BOOT" ]
}
modules_absent() {
    [ ! -d /sys/module/mttwt_once ] && [ ! -d /sys/module/mttwt_probe ] &&
        timeout 3 cat /proc/modules > "$V/modules.txt" &&
        ! grep -Eq '^(mttwt_once|mttwt_probe) ' "$V/modules.txt"
}
guard() {
    boot_ok || fail boot_changed 75
    modules_absent || fail temporary_module_loaded 75
}
framework_ready() {
    timeout 4 cmd wifi status > "$V/status.txt" 2>&1 &&
        grep -qx 'Wifi is enabled' "$V/status.txt" &&
        timeout 3 iw dev wlan0 info > "$V/interface.txt" 2>&1 &&
        timeout 3 ip link show dev wlan0 > "$V/netdev.txt" 2>&1
}
target_ready() {
    guard
    timeout 3 iw dev wlan0 link > "$V/link.txt" 2>&1 || return 1
    actual_ssid=$(sed -n 's/^[[:space:]]*SSID: //p' "$V/link.txt")
    actual_freq=$(awk '$1=="freq:" {print int($2)}' "$V/link.txt")
    actual_bssid=$(awk '$1=="Connected" && $2=="to" {print $3}' "$V/link.txt")
    [ "$actual_ssid" = "$SSID" ] && [ "$actual_freq" = "$FREQ" ] &&
        [ "$actual_bssid" = "$BSSID" ] || return 1
    timeout 4 cmd wifi status > "$V/status.txt" 2>&1 || return 1
    grep -Fxq "Wifi is connected to \"$SSID\"" "$V/status.txt" &&
        grep -Fq 'Supplicant state: COMPLETED' "$V/status.txt" &&
        grep -Fq "Frequency: ${FREQ}MHz" "$V/status.txt" || return 1
    timeout 3 ip -4 -o addr show dev wlan0 scope global > "$V/ip.txt" 2>&1 || return 1
    address=$(awk '$3=="inet" {split($4,a,"/"); print a[1]; exit}' "$V/ip.txt")
    case "$address" in ''|127.*|169.254.*|0.*) return 1 ;; esac
    timeout 3 ip -4 route get "$PEER" oif wlan0 > "$V/route.txt" 2>&1 || return 1
    awk -v expected="$address" '{for(i=1;i<NF;i++){if($i=="dev" && $(i+1)=="wlan0")d=1; if($i=="src" && $(i+1)==expected)s=1}} END{exit !(d && s)}' "$V/route.txt"
}

guard
deadline=$(( $(date +%s) + 20 ))
while ! framework_ready; do
    guard
    [ "$(date +%s)" -lt "$deadline" ] || fail framework_not_ready 69
    sleep 1
done
log framework_ready
if [ "$MODE" = select ]; then
    guard
    [ -s "$D/reconnect.key" ] && [ ! -L "$D/reconnect.key" ] || fail missing_key 66
    pass=$(cat "$D/reconnect.key") || fail unreadable_key 66
    # Keep the credential out of output and stage logs; no repeated selection.
    timeout 8 cmd wifi connect-network "$SSID" wpa3 "$pass" > "$V/connect.txt" 2>&1
    rc=$?
    unset pass
    log "selection_cli_rc=$rc"
    [ "$rc" = 0 ] || fail selection_command "$rc"
fi
deadline=$(( $(date +%s) + 35 ))
stable=0
while [ "$stable" -lt 2 ]; do
    if target_ready; then stable=$((stable + 1)); else stable=0; fi
    [ "$stable" -lt 2 ] || break
    [ "$(date +%s)" -lt "$deadline" ] || fail target_not_ready 69
    sleep 1
done
log target_ready
guard
if [ -n "$SIX" ]; then
    timeout 15 sh "$CHECKER" active "$SIX" > "$V/checker.txt" 2>&1
else
    timeout 15 sh "$CHECKER" active > "$V/checker.txt" 2>&1
fi
rc=$?
[ "$rc" = 0 ] && grep -qx 'RESULT fail=0' "$V/checker.txt" || fail checker_failed 70
timeout 10 ping -I wlan0 -c 3 -W 2 "$PEER" > "$V/ping.txt" 2>&1
rc=$?
[ "$rc" = 0 ] && grep -Eq '3 packets transmitted, 3 (packets )?received,.*0% packet loss' "$V/ping.txt" || fail connectivity_failed 71
# Reject a transient match that disappeared during checker or connectivity work.
target_ready || fail target_changed 69
guard
finish recovered verified 0
