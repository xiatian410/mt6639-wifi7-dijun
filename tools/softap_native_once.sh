#!/system/bin/sh
# Standalone native BSS; optional Android VIRTUAL downstream IP serving.
set -u
umask 077
D=${1:-} OP=${2:-} BAND=${3:-} WIDTH=${4:-20}
case "$D" in /data/local/tmp/mt6639-native-ap-*) ;; *) exit 64 ;; esac
[ -d "$D" ] && [ ! -L "$D" ] && [ "$(stat -c %u "$D")" = 0 ] &&
    [ "$(stat -c %a "$D")" = 700 ] && [ "$(id -u)" = 0 ] &&
    [ "$(id -Z)" = u:r:ksu:s0 ] || exit 77
# Sub-invocations (guardian, recover) may run without explicit arguments; fall
# back to the band this task was created for so recovery never mixes profiles.
if [ -z "$BAND" ]; then
    BAND=$(cat "$D/band" 2>/dev/null || true)
    [ -n "$BAND" ] || BAND=6g
fi
case "$BAND" in 2g|5g|6g) ;; *) exit 64 ;; esac
# Mutating/setup modes require the tested Enforcing posture. Recovery and the
# already-armed guardian must remain usable even if SELinux was changed later,
# otherwise a state change can make cleanup impossible.
case "$OP" in
    recover|guardian)
        case "$(getenforce)" in Enforcing|Permissive) ;; *) exit 77 ;; esac ;;
    *) [ "$(getenforce)" = Enforcing ] || exit 77 ;;
esac
[ "$(CDPATH= cd -P -- "$D" && pwd)" = "$D" ] || exit 77
SELF=$D/softap_native_once.sh
PROFILE=$D/softap_native_config.sh
IF=mtap0
# Always re-source the helper: it is idempotent and refreshes the Android
# runtime environment when a soft reboot replaced system_server, so a
# long-lived worker cannot hand us a stale BOOTCLASSPATH.
if [ -f /data/adb/modules/mt6639-hotspot/bin/android-env.sh ]; then
    . /data/adb/modules/mt6639-hotspot/bin/android-env.sh 2>/dev/null || true
fi
case "$BAND" in
    6g)
        UPSTREAM_SSID=LabNet-6G
        UPSTREAM_FREQ=6135
        UPSTREAM_BSSID=02:00:00:00:73:1c
        UPSTREAM_KEY_NAME=reconnect.key
        ;;
    2g)
        # The 2.4GHz C02 profile is documented against the LabNet-6G STA; the
        # documented 2.4GHz upstream is only used when the STA really sits on it.
        UPSTREAM_SSID=LabNet-2.4G
        UPSTREAM_FREQ=2412
        UPSTREAM_BSSID=02:00:00:00:73:1a
        UPSTREAM_KEY_NAME=reconnect-2g.key
        ;;
    5g)
        UPSTREAM_SSID=LabNet-2.4G
        UPSTREAM_FREQ=2412
        UPSTREAM_BSSID=02:00:00:00:73:1a
        UPSTREAM_KEY_NAME=reconnect-2g.key
        ;;
    *)
        exit 64
        ;;
esac
UPSTREAM_PEER=198.51.100.242
SIX=/data/adb/modules/mt6639-hotspot/six
UPSTREAM_CHECKER=$SIX/bin/post-reboot-check.sh
GUARDIAN_HOLD_SECONDS=${GUARDIAN_HOLD_SECONDS:-90}
case "$GUARDIAN_HOLD_SECONDS" in ''|*[!0-9]*) exit 64 ;; esac
[ "$GUARDIAN_HOLD_SECONDS" -ge 30 ] && [ "$GUARDIAN_HOLD_SECONDS" -le 86400 ] || exit 64
MODULE_GUARD_DIR=${MODULE_GUARD_DIR:-}
case "$MODULE_GUARD_DIR" in ''|/data/adb/modules/mt6639-hotspot) ;; *) exit 64 ;; esac
boot_ok() { [ "$(cat /proc/sys/kernel/random/boot_id)" = "$(cat "$D/boot.before")" ]; }
ap_value() {
    out=$(timeout 5 iwpriv wlan0 driver 'GET_CFG ApEHT') || return 1
    value=$(printf '%s\n' "$out" | sed -n 's/.*driver:[[:space:]]*//p' | tr -d '\r')
    case "$value" in 0|0x0) echo 0 ;; 1|0x1) echo 1 ;; *) return 1 ;; esac
}
set_ap() {
    timeout 5 iwpriv wlan0 driver "SET_CFG ApEHT $1" || return 1
    [ "$(ap_value)" = "$1" ] || return 1
    host=$(timeout 5 iwpriv wlan0 driver 'show-mld 255') || return 1
    printf '%s\n' "$host" | grep -Fxq "ApEHT:$1"
}
native_identity() {
    [ ! -L "$D/native.pid" ] && [ -f "$D/native.pid" ] &&
        [ ! -L "$D/native.start" ] && [ -s "$D/native.start" ] || return 1
    p=$(cat "$D/native.pid") || return 1
    case "$p" in ''|*[!0-9]*) return 1 ;; esac
    native_process_matches "$p" "$(cat "$D/native.start")"
}
native_process_matches() {
    probe_pid=$1 probe_start=${2:-}
    [ -d "/proc/$probe_pid" ] &&
        [ "$(readlink "/proc/$probe_pid/exe" 2>/dev/null)" = "$D/hostapd" ] || return 1
    probe_cmd=$(tr '\000' ' ' < "/proc/$probe_pid/cmdline" 2>/dev/null) || return 1
    case "$probe_cmd" in *"$D/ap.conf"*) ;; *) return 1 ;; esac
    [ -z "$probe_start" ] ||
        [ "$(awk '{print $22}' "/proc/$probe_pid/stat" 2>/dev/null)" = "$probe_start" ]
}
recover() {
    exec 9>"$D/recover.lock"
    flock -x 9 9>&9 || return 70
    boot_ok || return 78
    rc=0
    tether_state=not_requested
    tether_safe=1
    native_state=not_started
    interface_state=not_started
    driver_state=not_requested
    driver_safe=1
    station_state=not_checked
    reg_state=not_checked
    ip_forward_state=not_requested
    journal_ok=1
    record_recovery_state() {
        printf 'tether_state=%s\nnative_state=%s\ninterface_state=%s\ndriver_state=%s\nstation_state=%s\nreg_state=%s\nip_forward_state=%s\njournal_ok=%s\n' \
            "$tether_state" "$native_state" "$interface_state" "$driver_state" \
            "$station_state" "$reg_state" "$ip_forward_state" "$journal_ok" \
            > "$D/recovery.resources.tmp" &&
            mv "$D/recovery.resources.tmp" "$D/recovery.resources"
    }
    ensure_private_dir() {
        [ ! -L "$1" ] || return 1
        if [ ! -e "$1" ]; then mkdir "$1" || return 1; fi
        [ -d "$1" ] && [ ! -L "$1" ] &&
            [ "$(stat -c %u "$1")" = 0 ] && [ "$(stat -c %a "$1")" = 700 ]
    }
    if ! record_recovery_state; then journal_ok=0; rc=1; fi

    if [ -f "$D/tether.intent" ]; then
        tether_state=stop_pending
        if [ "$journal_ok" = 1 ] && ! record_recovery_state; then journal_ok=0; fi
        if [ "$journal_ok" = 1 ] && [ -f "$D/interface.index" ] &&
            [ -e "/sys/class/net/$IF/ifindex" ] &&
            [ "$(cat "/sys/class/net/$IF/ifindex")" = "$(cat "$D/interface.index")" ]; then
            hash=$(sha256sum "$D/native-tether.dex")
            if [ "${hash%% *}" = 71c2ff994fcc2f2ede23eeb361b9d153d9a72c00240ad90c677deb23827fea56 ]; then
                stop_rc=0
                CLASSPATH="$D/native-tether.dex" timeout 12 app_process /system/bin NativeTether stop "$D" > "$D/tether.stop" 2>&1 || stop_rc=1
                tether_active=unknown
                n=0
                while [ "$n" -lt 8 ]; do
                    if timeout 5 dumpsys tethering --short > "$D/tether.after" 2>&1; then
                        if grep -Eq "^[[:space:]]*$IF - (TetheredState|LocalHotspotState)" "$D/tether.after"; then
                            tether_active=1
                        else
                            tether_active=0
                            break
                        fi
                    else
                        tether_active=unknown
                        break
                    fi
                    sleep 1; n=$((n+1))
                done
                if [ "$stop_rc" = 0 ] && [ "$tether_active" = 0 ]; then
                    tether_state=stop_verified
                else
                    tether_state=unresolved_after_stop
                    tether_safe=0
                    rc=1
                fi
            else
                tether_state=unresolved_dex_hash
                tether_safe=0
                rc=1
            fi
        elif [ "$journal_ok" != 1 ]; then
            tether_state=unresolved_journal_failure
            tether_safe=0
            rc=1
        else
            tether_state=unresolved_interface_owner
            tether_safe=0
            rc=1
        fi
        record_recovery_state || { journal_ok=0; rc=1; }
    fi

    native_safe=1
    if [ -e "$D/native.pid" ]; then
        if [ -L "$D/native.pid" ] || [ ! -f "$D/native.pid" ]; then
            native_state=unresolved_pid_record
            native_safe=0
            rc=1
        else
            p=$(cat "$D/native.pid" 2>/dev/null || true)
            case "$p" in
                ''|*[!0-9]*)
                    native_state=unresolved_pid_record
                    native_safe=0
                    rc=1 ;;
                *)
                    if [ "$p" -le 1 ]; then
                        native_state=unresolved_pid_record
                        native_safe=0
                        rc=1
                    elif [ -d "/proc/$p" ] && native_identity; then
                        native_state=stop_pending
                        if [ "$journal_ok" = 1 ] && record_recovery_state; then
                            if native_identity; then
                                kill -TERM "$p" || rc=1
                                n=0
                                while [ -d "/proc/$p" ] && [ "$n" -lt 8 ]; do sleep 1; n=$((n+1)); done
                                if [ -d "/proc/$p" ]; then
                                    native_state=unresolved_process_alive
                                    native_safe=0
                                    rc=1
                                else
                                    native_state=stopped_verified
                                fi
                            else
                                native_state=unresolved_process_identity
                                native_safe=0
                                rc=1
                            fi
                        else
                            native_state=stop_skipped_journal_failure
                            native_safe=0
                            journal_ok=0
                            rc=1
                        fi
                    elif [ -d "/proc/$p" ] && [ ! -s "$D/native.start" ] &&
                        native_process_matches "$p" ""; then
                        native_state=stop_pending
                        if [ "$journal_ok" = 1 ] && record_recovery_state; then
                            if native_process_matches "$p" ""; then
                                kill -TERM "$p" || rc=1
                                n=0
                                while [ -d "/proc/$p" ] && [ "$n" -lt 8 ]; do sleep 1; n=$((n+1)); done
                                if [ -d "/proc/$p" ]; then
                                    native_state=unresolved_process_alive
                                    native_safe=0
                                    rc=1
                                else
                                    native_state=stopped_verified_without_starttime
                                fi
                            else
                                native_state=unresolved_process_identity
                                native_safe=0
                                rc=1
                            fi
                        else
                            native_state=stop_skipped_journal_failure
                            native_safe=0
                            journal_ok=0
                            rc=1
                        fi
                    elif [ -d "/proc/$p" ]; then
                        native_state=unresolved_process_identity
                        native_safe=0
                        rc=1
                    else
                        native_state=process_exited
                    fi ;;
            esac
        fi
    else
        # A process can start before its PID snapshot reaches disk. Recover it
        # only when both its executable and private config path identify this
        # unique task directory; never kill by process name alone.
        native_orphans=
        for proc_dir in /proc/[0-9]*; do
            proc_pid=${proc_dir##*/}
            native_process_matches "$proc_pid" "" || continue
            native_orphans="$native_orphans $proc_pid"
        done
        if [ -n "$native_orphans" ]; then
            native_state=orphan_stop_pending
            for p in $native_orphans; do
                if [ "$journal_ok" = 1 ] && record_recovery_state; then
                    if native_process_matches "$p" ""; then
                        kill -TERM "$p" || rc=1
                        n=0
                        while [ -d "/proc/$p" ] && [ "$n" -lt 8 ]; do sleep 1; n=$((n+1)); done
                        if [ -d "/proc/$p" ]; then
                            native_state=unresolved_orphan_alive
                            native_safe=0
                            rc=1
                        else
                            native_state=orphan_stopped
                        fi
                    else
                        native_state=unresolved_orphan_identity
                        native_safe=0
                        rc=1
                    fi
                else
                    native_state=unresolved_orphan_identity
                    native_safe=0
                    journal_ok=0
                    rc=1
                fi
            done
        else
            native_state=no_owned_process_found
        fi
    fi

    interface_safe=1
    if [ -e "/sys/class/net/$IF" ]; then
        if [ -f "$D/interface.index" ] && [ -e "/sys/class/net/$IF/ifindex" ] &&
            [ "$(cat "/sys/class/net/$IF/ifindex")" = "$(cat "$D/interface.index")" ] &&
            [ "$native_safe" = 1 ] && [ "$tether_safe" = 1 ]; then
            interface_state=remove_pending
            if [ "$journal_ok" = 1 ] && record_recovery_state &&
                [ -e "/sys/class/net/$IF/ifindex" ] &&
                [ "$(cat "/sys/class/net/$IF/ifindex")" = "$(cat "$D/interface.index")" ]; then
                helper_hash=$(sha256sum "$D/delete_ifindex" 2>/dev/null || true)
                if [ "${helper_hash%% *}" = d20169f8733dc3bd2813806b3deda79e84b497e40e4a0f82bb97cd585844d655 ]; then
                    delete_rc=0
                    timeout -s KILL 5 "$D/delete_ifindex" "$(cat "$D/interface.index")" > "$D/interface.remove" 2>&1 || delete_rc=$?
                    if [ "$delete_rc" = 0 ]; then
                        if [ ! -e "/sys/class/net/$IF" ]; then
                            # A successful DEL_INTERFACE ACK (or ENODEV) proves
                            # the recorded ifindex is gone; the absent name is
                            # consistent with that result.
                            interface_state=removed_verified
                        elif [ -e "/sys/class/net/$IF/ifindex" ]; then
                            if current_ifindex=$(cat "/sys/class/net/$IF/ifindex" 2>/dev/null); then
                                if [ "$current_ifindex" != "$(cat "$D/interface.index")" ]; then
                                    interface_state=removed_task_interface_name_reused
                                else
                                    interface_state=unresolved_after_remove
                                fi
                            else
                                interface_state=unresolved_ifindex_unreadable
                            fi
                            interface_safe=0
                            rc=1
                        else
                            interface_state=unresolved_ifindex_missing
                            interface_safe=0
                            rc=1
                        fi
                    else
                        case "$delete_rc" in
                            124|137) interface_state=delete_timeout ;;
                            *) interface_state=delete_failed ;;
                        esac
                        interface_safe=0
                        rc=1
                    fi
                else
                    interface_state=delete_helper_hash_mismatch
                    interface_safe=0
                    rc=1
                fi
            else
                interface_state=remove_skipped_journal_failure
                interface_safe=0
                journal_ok=0
                rc=1
            fi
        else
            interface_state=unresolved_owner_or_process
            interface_safe=0
            rc=1
        fi
    else
        interface_state=absent
    fi

    if [ -f "$D/tether.intent" ]; then
        if timeout 5 dumpsys tethering --short > "$D/tether.removed" 2>&1 &&
            ! grep -Eq "^[[:space:]]*$IF - (TetheredState|LocalHotspotState)" "$D/tether.removed" &&
            grep -Fxq '    Upstream wanted: false' "$D/tether.removed"; then
            [ "$tether_safe" = 1 ] && tether_state=interface_not_served
        else
            tether_state=unresolved_after_interface_cleanup
            rc=1
        fi
        if cat /proc/sys/net/ipv4/ip_forward > "$D/ip_forward.after" 2>&1 &&
            cmp -s "$D/ip_forward.before" "$D/ip_forward.after"; then
            ip_forward_state=restored
        else
            ip_forward_state=changed_or_unreadable
            rc=1
        fi
        record_recovery_state || { journal_ok=0; rc=1; }
    fi

    radio_safe=1
    [ "$native_safe" = 1 ] && [ "$interface_safe" = 1 ] || radio_safe=0
    if [ -f "$D/driver.intent" ]; then
        if [ "$radio_safe" = 1 ] && [ "$journal_ok" = 1 ] &&
            (cd "$D" && sha256sum -c before.sha256 >/dev/null 2>&1); then
            current=$(ap_value) || current=unknown
            before=$(cat "$D/ApEHT.before" 2>/dev/null || printf unknown)
            if { [ "$current" = 1 ] || [ "$current" = "$before" ]; } &&
                [ "$before" != unknown ]; then
                driver_state=restore_pending
                if [ "$journal_ok" = 1 ] && record_recovery_state &&
                    set_ap "$before" > "$D/driver.restore" 2>&1; then
                    driver_state=restored
                else
                    driver_state=restore_failed
                    driver_safe=0
                    rc=1
                fi
            else
                driver_state=unresolved_current_value
                driver_safe=0
                rc=1
            fi
        else
            driver_state=deferred_radio_or_backup_unresolved
            driver_safe=0
            rc=1
        fi
        record_recovery_state || { journal_ok=0; rc=1; }
    fi

    if timeout 5 iw reg get > "$D/reg.after" 2>&1 && cmp -s "$D/reg.before" "$D/reg.after"; then
        reg_state=restored
    else
        reg_state=changed_or_unreadable
        rc=1
    fi

    station_safe=1
    [ "$radio_safe" = 1 ] && [ "$tether_safe" = 1 ] &&
        [ "$driver_safe" = 1 ] && [ "$reg_state" = restored ] || station_safe=0
    check_dir=$D/network-recover-$$
    select_dir=$D/network-select-$$
    recover_mode=$(cat "$D/upstream.mode" 2>/dev/null || printf '%s\n' "${MT6639_HOTSPOT_UPSTREAM:-wifi}")
    case "$recover_mode" in
        wifi) station_required=1 ;;
        # cell starts with no STA connection by construction, and wifi-any was
        # never bound to the documented upstream SSID, so neither may be held
        # to a post-teardown reconnection of that SSID.
        *) station_required=0 ;;
    esac
    if [ "$station_required" = 0 ]; then
        station_state=not_required_$recover_mode
    elif ensure_private_dir "$check_dir" &&
        cp "$D/$UPSTREAM_KEY_NAME" "$check_dir/reconnect.key"; then
        # Tearing the AP down makes Android re-associate the STA. A check that
        # runs the instant the interface disappears loses that race, and the
        # fallback `select` then disconnects a connection that was only still
        # coming up — its own 20s verification window can expire, which showed up
        # as a false station_state=selection_failed / recovery_rc=1 on device.
        # Retry the read-only check for a bounded window before concluding loss.
        station_ok=0
        check_attempt=0
        while :; do
            if sh "$D/twt_recover.sh" check "$check_dir" "$(cat "$D/boot.before")" "$UPSTREAM_SSID" "$UPSTREAM_FREQ" "$UPSTREAM_BSSID" "$UPSTREAM_PEER" "$UPSTREAM_CHECKER" "$SIX" > "$D/network.check" 2>&1; then
                station_ok=1
                break
            fi
            check_attempt=$((check_attempt + 1))
            [ "$check_attempt" -lt "${MT6639_STATION_CHECK_TRIES:-8}" ] || break
            sleep 3
        done
        if [ "$station_ok" = 1 ]; then
            station_state=verified
        elif [ "$station_safe" = 1 ] && [ "$journal_ok" = 1 ]; then
            if ensure_private_dir "$select_dir" &&
                cp "$D/$UPSTREAM_KEY_NAME" "$select_dir/reconnect.key"; then
                station_state=selection_pending
                if record_recovery_state &&
                    sh "$D/twt_recover.sh" select "$select_dir" "$(cat "$D/boot.before")" "$UPSTREAM_SSID" "$UPSTREAM_FREQ" "$UPSTREAM_BSSID" "$UPSTREAM_PEER" "$UPSTREAM_CHECKER" "$SIX" > "$D/network.select" 2>&1; then
                    station_state=selected_and_verified
                else
                    station_state=selection_failed
                    rc=1
                fi
            else
                station_state=selection_dir_unavailable
                rc=1
            fi
        else
            station_state=deferred_unresolved_resources
            rc=1
        fi
    else
        station_state=recovery_dir_unavailable
        rc=1
    fi

    record_recovery_state || { journal_ok=0; rc=1; }

    # Terminal judgement. When the native runner has already exited, no mtap0
    # exists, the driver is back to station mode and the station verifies, the
    # access point is materially gone. A residual rc from a step that had nothing
    # left to do (e.g. stopping a tether whose interface no longer exists) must
    # not be reported as a failed teardown — the controller would then archive a
    # failure and, before v0.2.21, replay it forever. The original code is kept in
    # recovery.note so the downgrade stays auditable.
    case "$native_state" in
        process_exited|stopped_verified|stopped_verified_without_starttime)
            native_terminal=1 ;;
        *) native_terminal=0 ;;
    esac
    if [ "$rc" != 0 ] && [ "$native_terminal" = 1 ] &&
        [ "$interface_state" = absent ] && [ "$driver_state" = restored ] &&
        [ "$station_state" = verified ] && [ "$journal_ok" = 1 ]; then
        printf 'terminal_after_native_exit original_rc=%s native=%s\n' \
            "$rc" "$native_state" > "$D/recovery.note"
        rc=0
    fi
    printf '%s\n' "$rc" > "$D/recovery.rc"
    : > "$D/guardian.done"
    return "$rc"
}
case "$OP" in
    recover) recover; exit $? ;;
    guardian)
        : > "$D/guardian.ready"
        printf '%s\n' "$GUARDIAN_HOLD_SECONDS" > "$D/guardian.hold" || exit 74
        n=0
        while [ "$n" -lt "$GUARDIAN_HOLD_SECONDS" ] && [ ! -f "$D/cleanup.request" ]; do
            if [ -n "$MODULE_GUARD_DIR" ] &&
                { [ ! -d "$MODULE_GUARD_DIR" ] || [ -e "$MODULE_GUARD_DIR/disable" ] ||
                  [ -e "$MODULE_GUARD_DIR/remove" ]; }; then
                break
            fi
            sleep 1
            n=$((n+1))
        done
        recover; exit $? ;;
    run) ;;
    run-tether) ;;
    *) exit 64 ;;
esac
# Raw/staged entry points cannot bypass the installed owner's migration gate.
# The guardian/recovery dispatch above remains available during teardown.
sh /data/adb/modules/mt6639-hotspot/bin/unified-guard.sh \
    /data/adb/modules/mt6639-hotspot check || exit $?
exec 8>"$D/owner.lock"
flock -n 8 8>&8 || exit 75
# Holding owner.lock proves no other runner owns this directory, so a leftover
# claim from an earlier failed attempt is safe to drop; keeping it would make
# every retry die here with a bare exit 73.
rm -f "$D/claimed"
(set -C; : > "$D/claimed") 2>/dev/null || exit 73
# Recheck the staged reviewed identity before any radio mutation. The existing
# guardian/recover dispatch above deliberately remains independent of this gate.
if ! sh "$D/hotspot-identity.sh" "$D" > "$D/identity.check" 2>&1; then
    printf 'hotspot_identity_rejected\n' > "$D/failure"
    exit 69
fi
hash=$(sha256sum "$D/hostapd") || exit 69
[ "${hash%% *}" = 15023e3bfe6b08415ebcc92479c0cd4fb14adb57b9010266af73bcc1bdc7bc2b ] || exit 69
hash=$(sha256sum "$D/hostapd_cli") || exit 69
[ "${hash%% *}" = 2da7d467b7b2628c4da40fb5ccc101b17f8b279bd9c038c32e4ae6e5b2924a42 ] || exit 69
hash=$(sha256sum "$D/delete_ifindex") || exit 69
[ "${hash%% *}" = d20169f8733dc3bd2813806b3deda79e84b497e40e4a0f82bb97cd585844d655 ] || exit 69
hash=$(sha256sum "$D/softap-profile.dex") || exit 69
[ "${hash%% *}" = 7ff17f05008e77535dacac13c5c2f216c664bc26403d6cbfe7da7fb9b7c04017 ] || exit 69
# On builds without an init-managed hostapd the property is simply absent, so an
# empty value means "not running" just as much as "stopped".
hostapd_svc=$(getprop init.svc.hostapd)
{ [ -z "$hostapd_svc" ] || [ "$hostapd_svc" = stopped ]; } &&
    [ ! -e "/sys/class/net/$IF" ] ||
    { printf 'hostapd_svc=%s_if=%s\n' "$hostapd_svc" \
        "$( [ -e "/sys/class/net/$IF" ] && echo present || echo absent)" > "$D/failure"; exit 75; }
[ -s "$D/ap.conf" ] || exit 66
for file in "$PROFILE" "$D/ap.key" "$D/ap.conf"; do
    [ -f "$file" ] && [ ! -L "$file" ] && [ "$(stat -c %u "$file")" = 0 ] || exit 77
done
hash=$(sha256sum "$PROFILE") || exit 69
[ "${hash%% *}" = c1a0024f795f800eea6ac7566f6aeb0f159cb4082b73fac2e5be92927eaff0ba ] || exit 69
if [ -e "$D/ap.ssid.hex" ] || [ -L "$D/ap.ssid.hex" ]; then
    [ -f "$D/ssid_hex.sh" ] && [ ! -L "$D/ssid_hex.sh" ] &&
        [ "$(stat -c %u "$D/ssid_hex.sh")" = 0 ] || exit 77
    hash=$(sha256sum "$D/ssid_hex.sh") || exit 69
    [ "${hash%% *}" = 206c8349bc7891f539d74ba17f3cd5ea2a479b0539f02727bed642501891232d ] || exit 69
fi
sh "$PROFILE" "$D" check "$BAND" "$WIDTH" > "$D/profile.check" 2>&1 || exit 69
case "$BAND:$WIDTH" in
    5g:160)
        # DFS/CAC is not implemented for this candidate profile.
        echo REJECT_5GHz_160MHz_DFS_not_implemented >&2
        exit 69 ;;
esac
if ! CLASSPATH="$D/softap-profile.dex" timeout 8 app_process /system/bin WifiSoftApProfile inspect \
    > "$D/framework.before" 2> "$D/framework.err"; then
    inspect_rc=$?
    printf 'framework_inspect_failed rc=%s err=%s\n' "$inspect_rc" \
        "$(tr '\n' ' ' < "$D/framework.err" 2>/dev/null | head -c 200)" > "$D/failure"
    exit 69
fi
# app_process writes nothing at all when the Android runtime environment is
# missing, which previously looked like a bare exit 75. Name it instead.
[ -s "$D/framework.before" ] || {
    printf 'framework_inspect_empty android_env=%s\n' \
        "$( [ -n "${BOOTCLASSPATH:-}" ] && echo present || echo missing )" > "$D/failure"
    exit 69
}
grep -Fxq ap_state=11 "$D/framework.before" || {
    printf 'framework_ap_state_not_idle %s\n' \
        "$(tr '\n' ' ' < "$D/framework.before")" > "$D/failure"
    exit 75
}
if [ "$OP" = run-tether ]; then
    hash=$(sha256sum /apex/com.android.tethering/javalib/framework-tethering.jar) || exit 69
    [ "${hash%% *}" = 0b6f6c859301dae3276b9375c3b75333168dc5b76292ed9da03e29b59fc887bb ] || exit 69
    hash=$(sha256sum "$D/native-tether.dex") || exit 69
    [ "${hash%% *}" = 71c2ff994fcc2f2ede23eeb361b9d153d9a72c00240ad90c677deb23827fea56 ] || exit 69
    CLASSPATH="$D/native-tether.dex" timeout 8 app_process /system/bin NativeTether inspect > "$D/tether.api" 2>&1 || exit 69
    timeout 5 dumpsys tethering --short > "$D/tether.before" 2>&1 || exit 69
    grep -Fxq '    Upstream wanted: false' "$D/tether.before" &&
        grep -Fxq '    Current upstream interface(s): null' "$D/tether.before" || exit 75
    ! grep -Eq '^[[:space:]]*[^[:space:]]+ - (AvailableState|TetheredState|LocalHotspotState|UnavailableState)' "$D/tether.before" || exit 75
    cat /proc/sys/net/ipv4/ip_forward > "$D/ip_forward.before" || exit 69
fi
# Upstream modes:
#   wifi      verified baseline: the Wi-Fi STA is connected to this band's
#             documented upstream AP, which also provides the uplink
#   wifi-any  the STA is connected to some other network; the uplink is wlan0
#             and the exact upstream identity is not asserted
#   cell      no Wi-Fi STA connection; the WLAN driver stays loaded only
#             because Wi-Fi itself is enabled, and cellular data is the uplink
#   auto      decide per start from the current STA state (see below)
# The resolved mode is recorded in $D/upstream.mode so the guardian and any
# later recover run honour the contract this session actually started with.
timeout 5 cmd wifi status > "$D/sta.before" 2>&1 ||
    { printf 'sta_status_unavailable\n' > "$D/failure"; exit 69; }
UPSTREAM_MODE=$(sh "$D/hotspot-upstream.sh" "${MT6639_HOTSPOT_UPSTREAM:-auto}" "$BAND" "$D/sta.before") || {
    printf 'upstream_preflight_failed\n' > "$D/failure"; exit 69;
}
if [ "$UPSTREAM_MODE" = wifi ] && [ ! -s "$D/$UPSTREAM_KEY_NAME" ]; then
    printf 'missing_upstream_recovery_key\n' > "$D/failure"
    exit 66
fi
printf '%s\n' "$UPSTREAM_MODE" > "$D/upstream.mode" ||
    { printf 'upstream_mode_unwritable\n' > "$D/failure"; exit 74; }
case "$UPSTREAM_MODE" in
    cell) UPSTREAM_RE='Current upstream interface\(s\): \[(rmnet|wwan|ccmni|seth|eth)' ;;
    *) UPSTREAM_RE='Current upstream interface\(s\): \[wlan0\]' ;;
esac
if [ "$UPSTREAM_MODE" = cell ]; then
    # An AP interface can only be created while the WLAN driver is loaded, and
    # this driver is unloaded when Wi-Fi itself is turned off. A disconnected,
    # still-enabled STA is the state this mode is built for.
    grep -Fxq 'Wifi is enabled' "$D/sta.before" ||
        { printf 'wifi_disabled_driver_unavailable\n' > "$D/failure"; exit 69; }
    if grep -Fq 'Wifi is connected to "' "$D/sta.before"; then
        printf 'sta_connected_in_cell_mode\n' > "$D/failure"
        exit 69
    fi
    # Android tears the cellular data connection down while Wi-Fi carries the
    # default network, so the rmnet address only appears after the STA drops.
    # Give the modem a bounded window to attach before failing closed.
    n=0
    while :; do
        if timeout 5 ip -4 addr show > "$D/cell.addr" 2>&1 &&
            grep -Eq 'inet [0-9.]+/.* (rmnet|ccmni|wwan)[0-9]*' "$D/cell.addr"; then
            break
        fi
        [ "$n" -lt 10 ] || { printf 'cellular_data_unavailable\n' > "$D/failure"; exit 69; }
        sleep 1
        n=$((n+1))
    done
elif [ "$UPSTREAM_MODE" = wifi ]; then
    if ! { grep -Fxq "Wifi is connected to \"$UPSTREAM_SSID\"" "$D/sta.before" &&
        grep -Fq "BSSID: $UPSTREAM_BSSID" "$D/sta.before" &&
        grep -Fq "Frequency: ${UPSTREAM_FREQ}MHz" "$D/sta.before" &&
        grep -Fq 'Supplicant state: COMPLETED' "$D/sta.before"; }; then
        # Same SSID and same band, but a different node (a second AP of the same
        # mesh answers first). The band-level contract still holds for the 6GHz
        # profile — the STA is on 6GHz and the uplink is wlan0 — only the BSSID /
        # channel pin does not. Downgrade explicitly instead of failing a start
        # the user asked for from Settings, and record why.
        sta_freq=$(sed -n 's/.*Frequency: \([0-9][0-9]*\)MHz.*/\1/p' "$D/sta.before" | head -1)
        case "$sta_freq" in ''|*[!0-9]*) sta_freq=0 ;; esac
        if [ "$BAND" = 6g ] &&
            grep -Fxq "Wifi is connected to \"$UPSTREAM_SSID\"" "$D/sta.before" &&
            grep -Fq 'Supplicant state: COMPLETED' "$D/sta.before" &&
            [ "$sta_freq" -ge 5950 ] && [ "$sta_freq" -le 7125 ]; then
            UPSTREAM_MODE=wifi-any
            printf '%s\n' "$UPSTREAM_MODE" > "$D/upstream.mode" ||
                { printf 'upstream_mode_unwritable\n' > "$D/failure"; exit 74; }
            printf 'upstream_downgraded sta_freq=%s pinned=%s/%s reason=bssid_pin_mismatch\n' \
                "$sta_freq" "$UPSTREAM_FREQ" "$UPSTREAM_BSSID" > "$D/upstream.note"
        else
            printf 'sta_upstream_mismatch\n' > "$D/failure"
            exit 69
        fi
    fi
fi
# Measured on this firmware: with the STA connected on a 5GHz channel the driver
# moves an AP interface created for 6135 over to the STA's channel
# ("CTRL-EVENT-CHANNEL-SWITCH freq=5180"), so single-channel concurrency is
# enforced below 6GHz. Refuse that combination up front instead of creating an
# interface that silently stops being a 6GHz BSS.
if [ "$BAND" = 6g ] && [ "$UPSTREAM_MODE" != cell ]; then
    sta_freq=$(sed -n 's/.*Frequency: \([0-9][0-9]*\)MHz.*/\1/p' "$D/sta.before" | head -1)
    case "$sta_freq" in
        ''|*[!0-9]*) printf 'sta_frequency_unknown\n' > "$D/failure"; exit 69 ;;
    esac
    if [ "$sta_freq" -lt 5950 ] || [ "$sta_freq" -gt 7125 ]; then
        printf 'sta_band_incompatible_with_6g sta_freq=%s\n' "$sta_freq" > "$D/failure"
        exit 69
    fi
fi
# Same single-channel rule below 6GHz for the 2.4GHz C02 profile: an AP on
# 2437 next to a 2.4GHz STA would be relocated to the STA's channel.
if [ "$BAND" = 2g ] && [ "$UPSTREAM_MODE" != cell ]; then
    sta_freq=$(sed -n 's/.*Frequency: \([0-9][0-9]*\)MHz.*/\1/p' "$D/sta.before" | head -1)
    case "$sta_freq" in
        ''|*[!0-9]*) printf 'sta_frequency_unknown\n' > "$D/failure"; exit 69 ;;
    esac
    if [ "$sta_freq" -ge 2400 ] && [ "$sta_freq" -le 2484 ]; then
        printf 'sta_band_incompatible_with_2g sta_freq=%s\n' "$sta_freq" > "$D/failure"
        exit 69
    fi
fi
"$D/hostapd" --mt6639-check-config "$D/ap.conf" > "$D/config.check" 2>&1 || exit 69
cat /proc/sys/kernel/random/boot_id > "$D/boot.before" || exit 74
timeout 5 iw reg get > "$D/reg.before" || exit 69
timeout 5 iw dev > "$D/interfaces.before" || exit 69
ap_value > "$D/ApEHT.before" || exit 69
mkdir "$D/backup" || exit 73
for file in /odm/firmware/wifi.cfg /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml; do
    cp -p "$file" "$D/backup/$(basename "$file")" || exit 74
    hash=$(sha256sum "$file" | cut -d ' ' -f 1)
    [ "$hash" = "$(sha256sum "$D/backup/$(basename "$file")" | cut -d ' ' -f 1)" ] || exit 74
    echo "$hash $file" >> "$D/backup/SHA256.txt"
done
(cd "$D" && sha256sum boot.before ApEHT.before reg.before > before.sha256) || exit 74
# The guardian re-executes this script, so it must be told the same band: its
# recovery path picks $UPSTREAM_KEY_NAME / SSID / BSSID from that argument and
# would otherwise fall back to the 6GHz defaults for a 5g/2g session.
printf '%s\n' "$BAND" > "$D/band" || exit 74
nohup sh "$SELF" "$D" guardian "$BAND" "$WIDTH" > "$D/guardian.log" 2>&1 8>&8 < /dev/null &
guard=$!
printf '%s\n' "$guard" > "$D/guardian.pid" || { kill "$guard" 2>/dev/null; exit 74; }
awk '{print $22}' "/proc/$guard/stat" > "$D/guardian.start" || {
    kill "$guard" 2>/dev/null
    exit 74
}
n=0
while [ ! -f "$D/guardian.ready" ] && [ "$n" -lt 5 ]; do sleep 1; n=$((n+1)); done
[ -f "$D/guardian.ready" ] && kill -0 "$guard" || exit 70
trap ': > "$D/cleanup.request"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
exec 9>"$D/recover.lock"
flock -x 9 9>&9 || exit 75
boot_ok && kill -0 "$guard" || exit 78
: > "$D/driver.intent"
action_rc=1
# 2.4GHz runs HE only; asking the driver for EHT there would advertise a
# capability hostapd is not configured to use.
case "$BAND" in
    2g) WANT_AP_EHT=0 ;;
    *) WANT_AP_EHT=1 ;;
esac
printf '%s\n' "$WANT_AP_EHT" > "$D/driver.target" || exit 74
if set_ap "$WANT_AP_EHT" > "$D/driver.enable" 2>&1; then
    : > "$D/interface.intent"
    timeout 5 iw phy phy0 interface add "$IF" type __ap > "$D/interface.create" 2>&1
    create_rc=$?
    if [ "$create_rc" = 0 ] && [ -e "/sys/class/net/$IF/ifindex" ]; then
        cat "/sys/class/net/$IF/ifindex" > "$D/interface.index"
        nohup "$D/hostapd" -ddd "$D/ap.conf" > "$D/native.log" 2>&1 < /dev/null 8>&8 9>&9 &
        echo "$!" > "$D/native.pid"
        awk '{print $22}' "/proc/$!/stat" > "$D/native.start"
        n=0
        while [ "$n" -lt 4 ]; do
            native_identity && break
            kill -0 "$(cat "$D/native.pid")" 2>/dev/null || break
            sleep 1; n=$((n+1))
        done
        native_identity && action_rc=0
    fi
fi
flock -u 9 9>&9
exec 9>&-
if [ "$action_rc" = 0 ]; then
    n=0
    while [ "$n" -lt 12 ]; do
        timeout 4 "$D/hostapd_cli" -p "$D/ctrl" -i "$IF" status > "$D/status.active" 2>&1
        grep -Fxq state=ENABLED "$D/status.active" && break
        native_identity || break
        sleep 1; n=$((n+1))
    done
    sh "$PROFILE" "$D" status "$BAND" "$WIDTH" > "$D/profile.active" 2>&1 || action_rc=1
    timeout 5 iw dev "$IF" info > "$D/interface.active" 2>&1 || action_rc=1
    timeout 5 cmd wifi status > "$D/sta.active" 2>&1
    if [ "$action_rc" = 0 ] && [ "$OP" = run-tether ]; then
        : > "$D/tether.intent"
        CLASSPATH="$D/native-tether.dex" timeout 12 app_process /system/bin NativeTether start "$D" > "$D/tether.start" 2>&1 || action_rc=1
        n=0
        while [ "$action_rc" = 0 ] && [ "$n" -lt 8 ]; do
            timeout 5 dumpsys tethering --short > "$D/tether.active" 2>&1 || action_rc=1
            grep -Eq "^[[:space:]]*$IF - TetheredState - lastError = 0$" "$D/tether.active" &&
                grep -Eq "$UPSTREAM_RE" "$D/tether.active" && break
            sleep 1; n=$((n+1))
        done
        if grep -Eq "^[[:space:]]*$IF - TetheredState - lastError = 0$" "$D/tether.active" &&
            grep -Fxq '    Upstream wanted: true' "$D/tether.active" &&
            grep -Eq "$UPSTREAM_RE" "$D/tether.active"; then
            :
        else
            action_rc=1
            printf 'upstream_mismatch mode=%s actual=%s\n' "$UPSTREAM_MODE" \
                "$(sed -n 's/.*Current upstream interface(s): //p' "$D/tether.active" 2>/dev/null | tr -d '\n')" \
                > "$D/failure"
        fi
        timeout 5 ip -4 addr show dev "$IF" > "$D/address.active" 2>&1 || action_rc=1
        grep -q 'inet ' "$D/address.active" || action_rc=1
        timeout 5 iptables-save -t nat > "$D/nat.active" 2>&1
        timeout 5 iptables-save -t filter > "$D/filter.active" 2>&1
        timeout 5 dumpsys network_stack > "$D/network-stack.active" 2>&1
        timeout 5 dumpsys netd > "$D/netd.active" 2>&1
    fi
fi
if [ "$action_rc" = 0 ]; then
    # Detect a channel switch during IP serving setup before reporting success.
    if native_identity &&
        timeout 4 "$D/hostapd_cli" -p "$D/ctrl" -i "$IF" status > "$D/status.active" 2>&1 &&
        sh "$PROFILE" "$D" status "$BAND" "$WIDTH" > "$D/profile.final" 2>&1; then
        :
    else
        action_rc=1
        printf 'final_check_failed %s\n' \
            "$(tr '\n' ' ' < "$D/profile.final" 2>/dev/null)" > "$D/failure"
    fi
fi
printf '%s\n' "$action_rc" > "$D/action.rc"
[ "$action_rc" = 0 ] || : > "$D/cleanup.request"
wait "$guard"
guard_rc=$?
[ "$action_rc" = 0 ] && [ "$guard_rc" = 0 ] && [ "$(cat "$D/recovery.rc")" = 0 ] || exit 71
case "$BAND" in
    2g) PHY_LABEL=HE ;;
    *) PHY_LABEL=EHT ;;
esac
if [ "$OP" = run-tether ]; then
    echo "RESULT=native_${BAND}_${WIDTH}MHz_${PHY_LABEL}_BSS_Android_IP_serving_checked_and_restored_peer_unverified"
else
    echo "RESULT=native_${BAND}_${WIDTH}MHz_${PHY_LABEL}_BSS_checked_and_restored_peer_and_tethering_unverified"
fi
