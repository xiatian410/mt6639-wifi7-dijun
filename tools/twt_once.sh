#!/system/bin/sh
# A new, version-locked single trial. Never reuse the historical runners.
# run|action|guardian TASK BOOT SSID FREQ BSSID PEER CHECKER
# TASK must contain this script as trial.sh, recover.sh, once.ko, reconnect.key,
# and five refreshed backups. Launch run via nohup from the prepared task.
set -u
umask 077
[ "$#" -eq 8 ] || exit 64
MODE=$1 D=$2 BOOT=$3 SSID=$4 FREQ=$5 BSSID=$6 PEER=$7 CHECKER=$8
case "$MODE" in run|action|guardian) ;; *) exit 64 ;; esac
case "$D" in /*) ;; *) exit 64 ;; esac
[ -d "$D" ] && [ ! -L "$D" ] || exit 64
[ "$(id -u)" = 0 ] || exit 77
[ "$(stat -c '%u:%a' "$D")" = 0:700 ] || exit 77
# Deploy every new trial under the same root-private parent, normally
# /data/local/tmp/mt6639-twt (shell_data_file for cmd's Binder output FDs).
# Descriptor 8 is deliberately inherited by the guardian
# so the cross-trial lock survives loss of run's foreground process.
P=${D%/*}
[ -d "$P" ] && [ ! -L "$P" ] && [ "$(stat -c '%u:%a' "$P")" = 0:700 ] || exit 77
if [ "$MODE" = run ]; then
    [ ! -L "$P/.mt6639-twt.lock" ] || exit 75
    exec 8>> "$P/.mt6639-twt.lock"
fi
# Android mksh marks persistent descriptors close-on-exec. Explicitly
# redirect them on every external consumer (and on spawned actor shells).
flock -n 8 8>&8 || exit 75
MOD=mttwt_once
KO_HASH=a68139b1aa1f9e83b241445f41e9d1a142e4826309c8b4301efd82ad2442e61e
STOCK_HASH=54619c2e9521fc084edd4ec93282715ac10e716ad4ae0a27ec5588fb64e618ea
BTF_HASH=cff622b3a38fce9b608b7063ab93025118fd2afd8d32b187174d7473751d1be2
RECOVER_HASH=7f6b7bab02199645a09f25cebbeeb79d06f31bbf33386eae89d86bf8b63f59cf
sha() { timeout 5 sha256sum "$1" | awk '{print $1}'; }
current() { [ "$(timeout 3 cat /proc/sys/kernel/random/boot_id)" = "$BOOT" ]; }
loaded() {
    timeout 3 cat /proc/modules > "$D/modules-$MODE.txt" || return 2
    grep -q "^$MOD " "$D/modules-$MODE.txt"
}
log() { printf '%s %s\n' "$(date +%s)" "$*" >> "$D/guardian.log"; }
result() {
    printf 'status=%s\nstage=%s\nrc=%s\n' "$1" "$2" "$3" > "$D/result.tmp" &&
        mv "$D/result.tmp" "$D/result.txt" || exit 74
    if [ "$1" = recovered ]; then : > "$D/recovered" || exit 74; fi
    printf 'RESULT %s stage=%s rc=%s\n' "$1" "$2" "$3"
    exit "$3"
}
artifact_ok() {
    for f in trial.sh recover.sh once.ko reconnect.key; do
        [ -s "$D/$f" ] && [ ! -L "$D/$f" ] || return 1
    done
    [ "$(stat -c '%u:%a' "$D/reconnect.key")" = 0:600 ] &&
        [ "$(sha "$D/recover.sh")" = "$RECOVER_HASH" ] &&
        [ "$(sha "$D/once.ko")" = "$KO_HASH" ] &&
        [ "$(sha /vendor/lib/modules/wlan_drv_gen4m_eap_6639.ko)" = "$STOCK_HASH" ] &&
        [ "$(sha /sys/kernel/btf/vmlinux)" = "$BTF_HASH" ]
}
backup_ok() {
    while IFS='|' read -r name path; do
        [ -s "$D/backup/$name" ] && [ ! -L "$D/backup/$name" ] || return 1
        before=$(sha "$path")
        [ "${#before}" = 64 ] && [ "$before" = "$(sha "$D/backup/$name")" ] || return 1
    done <<'FILES'
wifi.cfg|/odm/firmware/wifi.cfg
config.conf|/data/adb/modules/mt6639-6g/config.conf
module.prop|/data/adb/modules/mt6639-6g/module.prop
WifiConfigStore-shared.xml|/data/misc/apexdata/com.android.wifi/WifiConfigStore.xml
WifiConfigStore-user0.xml|/data/misc_ce/0/apexdata/com.android.wifi/WifiConfigStore.xml
FILES
}
recover() {
    mode=$1 sub=$2
    mkdir "$D/$sub" || return 73
    if [ "$mode" = select ]; then
        cp "$D/reconnect.key" "$D/$sub/reconnect.key" || return 74
        chmod 600 "$D/$sub/reconnect.key" || return 74
    fi
    # Outer deadline also bounds pathological repeated per-command timeouts.
    timeout -k 2 180 sh "$D/recover.sh" "$mode" "$D/$sub" "$BOOT" \
        "$SSID" "$FREQ" "$BSSID" "$PEER" "$CHECKER" > "$D/$sub.log" 2>&1 8>&8
    rc=$?
    [ "$rc" = 0 ] && [ -f "$D/$sub/verification/recovered" ] &&
        grep -qx 'status=recovered' "$D/$sub/verification/result.txt"
}

if [ "$MODE" = action ]; then
    [ -d "$D/run-once" ] && [ -s "$D/guardian.pid" ] || exit 75
    # This open file description is distinct from the guardian's descriptor.
    exec 9>> "$D/action.lock"
    flock -n 9 9>&9 || exit 75
    [ ! -e "$D/stop-setup" ] && current && artifact_ok || exit 75
    : > "$D/module-load-intent" || exit 74
    timeout -k 2 8 insmod "$D/once.ko" > "$D/insmod.txt" 2>&1 8>&8 9>&9
    rc=$?
    [ "$rc" = 0 ] && loaded || exit 70
    [ ! -e "$D/stop-setup" ] && current || exit 75
    : > "$D/setup-attempted" || exit 74
    timeout -k 2 8 iwpriv wlan0 driver 'SET_TWT_PARAMS 4 0 0 0 0 8 0 64 128' > "$D/setup.txt" 2>&1 8>&8 9>&9
    exit "$?"
fi

if [ "$MODE" = guardian ]; then
    [ -d "$D/run-once" ] && mkdir "$D/guardian-once" || exit 73
    current || result failed boot_changed 75
    # Hold our own lock descriptor; do not inherit the action's descriptor.
    exec 9>> "$D/action.lock"
    printf '%s\n' "$$" > "$D/guardian.pid" || exit 74
    log armed
    : > "$D/armed" || exit 74
    sleep 20
    : > "$D/stop-setup" || result failed stop_marker 74
    # run bounds the entire action at 20s (+2s kill grace). The lock prevents
    # an in-flight Request from racing cleanup, even if the host disappears.
    timeout -k 2 26 flock 9 9>&9 || result failed action_lock_timeout 75
    current || result failed boot_changed 75
    radio_dirty=0
    emergency_enable() {
        if [ "$radio_dirty" = 1 ] && current; then
            timeout -k 2 8 cmd wifi set-wifi-enabled enabled >> "$D/emergency-enable.txt" 2>&1
        fi
    }
    trap emergency_enable EXIT
    trap 'exit 70' HUP INT TERM
    loaded
    module_rc=$?
    [ "$module_rc" -le 1 ] || result failed module_state_unreadable 75
    if [ "$module_rc" = 0 ] && [ ! -f "$D/module-load-intent" ]; then
        result failed foreign_module 75
    fi
    cycle_ok=1
    if [ -f "$D/setup-attempted" ]; then
        if [ "$module_rc" = 0 ]; then
            timeout -k 2 8 iwpriv wlan0 driver 'SET_TWT_PARAMS 5 0' > "$D/teardown.txt" 2>&1
            log "teardown_cli_rc=$?"
        fi
        sleep 5
        current || result failed boot_changed 75
        radio_dirty=1
        timeout -k 2 8 cmd wifi set-wifi-enabled disabled > "$D/radio-disable.txt" 2>&1
        rc=$?
        [ "$rc" = 0 ] || cycle_ok=0
        # A CLI success alone does not prove that the old STA ended.
        down=0 i=0
        while [ "$i" -lt 5 ]; do
            if timeout 4 cmd wifi status > "$D/radio-status.txt" 2>&1 &&
                    grep -qx 'Wifi is disabled' "$D/radio-status.txt"; then down=1; break; fi
            i=$((i + 1)); sleep 1
        done
        [ "$down" = 1 ] || cycle_ok=0
        current || result failed boot_changed 75
        timeout -k 2 8 cmd wifi set-wifi-enabled enabled > "$D/radio-enable.txt" 2>&1
        rc=$?
        [ "$rc" = 0 ] && radio_dirty=0
        [ "$rc" = 0 ] || cycle_ok=0
    fi
    current || result failed boot_changed 75
    if loaded; then
        timeout -k 2 8 rmmod "$MOD" > "$D/unload.txt" 2>&1
        rc=$?
        [ "$rc" = 0 ] || result failed normal_unload_failed 75
    fi
    loaded
    [ "$?" = 1 ] || result failed module_still_loaded 75
    [ "$cycle_ok" = 1 ] || result failed old_sta_not_terminated 71
    if [ -f "$D/setup-attempted" ]; then mode=select; else mode=check; fi
    recover "$mode" final || result failed network_verification_failed 71
    current || result failed boot_changed 75
    log network_verified
    trap - EXIT
    result recovered network_verified 0
fi

# run: all failures before arming are side-effect-free for WLAN/TWT.
mkdir "$D/run-once" || exit 73
current || result failed boot_changed 75
artifact_ok || result failed artifact_mismatch 75
backup_ok || result failed backup_mismatch 75
recover check preflight || result failed preflight_network_failed 71
current || result failed boot_changed 75
nohup sh "$D/trial.sh" guardian "$D" "$BOOT" "$SSID" "$FREQ" "$BSSID" "$PEER" "$CHECKER" \
    > "$D/guardian.out" 2>&1 < /dev/null 8>&8 9>&- &
guardian=$!
i=0
while [ ! -f "$D/armed" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
if [ ! -f "$D/armed" ] || [ "$(cat "$D/guardian.pid" 2>/dev/null)" != "$guardian" ] ||
        ! kill -0 "$guardian" 2>/dev/null; then
    # No action has started. A late guardian may still finish a read-only check.
    exit 70
fi
timeout -k 2 20 sh "$D/trial.sh" action "$D" "$BOOT" "$SSID" "$FREQ" "$BSSID" "$PEER" "$CHECKER" \
    > "$D/action.out" 2>&1 8>&8
action_rc=$?
printf '%s\n' "$action_rc" > "$D/action.rc"
wait "$guardian"
guardian_rc=$?
printf 'action_rc=%s recovery_rc=%s\n' "$action_rc" "$guardian_rc"
[ "$guardian_rc" = 0 ] && [ -f "$D/recovered" ] || exit 71
# Recovered is a network recovery result, never proof of TWT Accept or savings.
[ "$action_rc" = 0 ] || exit "$action_rc"
exit 0
