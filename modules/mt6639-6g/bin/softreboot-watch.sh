#!/system/bin/sh
# Soft-reboot watchdog for the 6GHz transaction.
#
# A soft reboot restarts system_server but leaves the kernel boot id, the 6GHz
# transaction, its guardian and the cfg bind untouched. Android's Wi-Fi country
# override lives in system_server memory, so it falls back to
# ro.boot.wificountrycode (CN) and every 6GHz channel becomes (disabled) again
# while the transaction still reports state=active. Nothing else notices, so
# 6GHz silently disappears until someone runs refresh-6g.sh by hand.
#
# It runs two entry points into the same decision:
#   - fast lane: system_server changed inside the same kernel boot;
#   - slow lane: a periodic integrity pass, because a cold boot, a mid-boot
#     module load or any other silent loss of the country override looks exactly
#     the same from the inside (state=active, guardian alive, 6135MHz missing).
# In both cases it only acts when 6135MHz is really absent, the transaction is
# still active and Wi-Fi was already on. It never creates, resumes or tears down
# a transaction, never turns Wi-Fi on, and stops after a fixed number of attempts
# per kernel boot (a success resets the budget).
set -u
MODDIR=${1:-${MODDIR:-/data/adb/modules/mt6639-6g}}
MODE=${2:-run}
. "$MODDIR/bin/owner.sh"
require_owner_mutation || exit 3
if [ "$MODULE_EMBEDDED" = 1 ]; then require_owner_enabled || exit 3; fi
. "$MODDIR/bin/lib.sh"
[ -f "$MODDIR/config.conf" ] && . "$MODDIR/config.conf"

WATCH=$WORK/softreboot-watch
mkdir -p "$WATCH" 2>/dev/null || exit 3
chmod 0700 "$WATCH" 2>/dev/null || exit 3
WLOG=$WATCH/watch.log
STATE_FILE=$WATCH/state
LOCK=$WATCH/watch.lock
PID_FILE=$WATCH/pid
# Keep this subsystem's records out of apply.log.
LOG=$WLOG

MAX_ATTEMPTS=${MT6639_WATCH_MAX_ATTEMPTS:-2}
INTERVAL=${MT6639_WATCH_INTERVAL:-5}
ITERATIONS=${MT6639_WATCH_ITER:-0}
# Seconds between integrity passes. 0 disables them (tests drive them explicitly).
CHECK_INTERVAL=${MT6639_WATCH_CHECK_INTERVAL:-60}
last_check=0

ss_pid() {
    if [ "${MT6639_TEST_MODE:-0}" = 1 ] && [ -n "${SYSTEM_SERVER_PID_FILE:-}" ]; then
        sed -n '1p' "$SYSTEM_SERVER_PID_FILE" 2>/dev/null
        return 0
    fi
    pidof system_server 2>/dev/null | awk '{print $1}'
}

wifi_on() {
    if [ "${MT6639_TEST_MODE:-0}" = 1 ] && [ -n "${MT6639_TEST_WIFI_ON:-}" ]; then
        printf '%s\n' "$MT6639_TEST_WIFI_ON"
        return 0
    fi
    read_setting wifi_on
}

# 6135MHz enabled in the current driver generation? Parse like refresh-6g.sh so
# both agree on what "registered" means; a failed iw run is never "absent".
target_registered() {
    dump=$WATCH/iw-phy.$$
    if ! iw phy >"$dump" 2>&1; then
        rm -f "$dump"
        return 2
    fi
    count=$(awk '
        /^[[:space:]]*\* [0-9]+(\.[0-9]+)? MHz/ {
            if ($0 ~ /\(disabled\)/) next
            mhz=$2
            sub(/\..*/, "", mhz)
            gsub(/[^0-9]/, "", mhz)
            if (mhz == 6135) count++
        }
        END { print count + 0 }
    ' "$dump")
    rc=$?
    rm -f "$dump"
    [ "$rc" = 0 ] || return 2
    case "$count" in ''|*[!0-9]*) return 2 ;; esac
    [ "$count" -gt 0 ]
}

run_refresh() {
    if [ "$MODULE_EMBEDDED" = 1 ]; then
        require_owner_enabled && require_owner_mutation || return 3
        timeout 200 sh "$MODULE_OWNER/bin/radio-control.sh" "$MODULE_OWNER" six-refresh
        return $?
    fi
    if [ "${MT6639_TEST_MODE:-0}" = 1 ] && [ -n "${MT6639_TEST_REFRESH_CMD:-}" ]; then
        sh -c "$MT6639_TEST_REFRESH_CMD"
        return $?
    fi
    timeout 200 sh "$MODDIR/bin/control.sh" "$MODDIR" refresh
}

# Right after `ctl.restart zygote` the Wi-Fi service and the settings provider are
# still coming up, and refresh-6g.sh then fails closed with
# country_baseline_unreadable (observed 22:12:53 on device). Wait for the service
# to answer before spending an attempt.
wait_wifi_ready() {
    tries=${MT6639_WATCH_READY_TRIES:-20}
    n=0
    while [ "$n" -lt "$tries" ]; do
        n=$((n + 1))
        if out=$(wifi status 2>&1); then
            case "$out" in
                *'Wifi is enabled'*) return 0 ;;
            esac
        fi
        sleep 3
    done
    return 1
}

load_state() {
    s_boot= s_ss= s_attempts=0
    if [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ]; then
        s_boot=$(sed -n 's/^boot=//p' "$STATE_FILE" | head -1)
        s_ss=$(sed -n 's/^ss=//p' "$STATE_FILE" | head -1)
        s_attempts=$(sed -n 's/^attempts=//p' "$STATE_FILE" | head -1)
    fi
    case "$s_attempts" in ''|*[!0-9]*) s_attempts=0 ;; esac
}

save_state() {
    { printf 'boot=%s\n' "$1"; printf 'ss=%s\n' "$2"; printf 'attempts=%s\n' "$3"; } \
        >"$STATE_FILE" 2>/dev/null
}

# Single place that is allowed to spend an attempt. $1 only labels the caller in
# the log; the decision itself is identical for both entry points.
try_refresh() {
    reason=$1
    boot=$(boot_id 2>/dev/null)
    ss=$(ss_pid)
    [ -n "$boot" ] || return 0
    load_state
    if [ "$boot" != "$s_boot" ]; then
        save_state "$boot" "$ss" 0
        s_boot=$boot
        s_ss=$ss
        s_attempts=0
    fi
    if ! target_registered; then
        :
    else
        [ "$reason" = soft ] && log "softreboot-watch: target_6135_registered; nothing to do"
        return 0
    fi
    case "$(cat "$STATE" 2>/dev/null)" in
        active) ;;
        *) [ "$reason" = soft ] && log "softreboot-watch: no_active_transaction; skip"; return 0 ;;
    esac
    on=$(wifi_on)
    case "$on" in
        1) ;;
        *) [ "$reason" = soft ] && log "softreboot-watch: wifi_off; skip (will not enable Wi-Fi)"; return 0 ;;
    esac
    if [ "$s_attempts" -ge "$MAX_ATTEMPTS" ]; then
        log "softreboot-watch: ${reason}: suppressed attempts=$s_attempts (limit=$MAX_ATTEMPTS)"
        return 0
    fi
    s_attempts=$((s_attempts + 1))
    save_state "$boot" "$ss" "$s_attempts"
    run_refresh >>"$WLOG" 2>&1
    rc=$?
    log "softreboot-watch: ${reason}: refresh rc=$rc attempt=$s_attempts/$MAX_ATTEMPTS"
    # A success clears the budget: a later soft reboot in the same kernel boot
    # (restoring LSPosed also restarts zygote) must get its own attempt.
    if [ "$rc" = 0 ]; then
        save_state "$boot" "$ss" 0
    fi
    return 0
}

handle_change() {
    boot=$1
    ss=$2
    load_state
    if [ -z "$s_boot" ]; then
        # First observation: record it, and let service.sh own registration.
        save_state "$boot" "$ss" 0
        log "softreboot-watch: baseline boot=$boot ss=$ss"
        return 0
    fi
    if [ "$boot" != "$s_boot" ]; then
        log "softreboot-watch: boot_changed old=$s_boot new=$boot; cold boot owns registration"
        save_state "$boot" "$ss" 0
        return 0
    fi
    [ "$ss" = "$s_ss" ] && return 0

    log "softreboot-watch: soft_reboot old_ss=$s_ss new_ss=$ss boot=$boot"
    save_state "$boot" "$ss" "$s_attempts"
    if ! wait_wifi_ready; then
        log "softreboot-watch: wifi_service_not_ready; skip (run refresh by hand if 6GHz stays unregistered)"
        return 0
    fi
    # The soft-reboot path is only the fast lane; try_refresh decides.
    try_refresh soft
}

# Periodic integrity pass. It exists because a cold boot, a mid-boot module load
# or any other silent loss of the country override looks exactly like the
# soft-reboot case from the inside: state=active, guardian alive, 6135 missing.
integrity_check() {
    load_state
    boot=$(boot_id 2>/dev/null)
    if [ -n "$boot" ] && [ "$boot" != "$s_boot" ]; then
        save_state "$boot" "$(ss_pid)" 0
        return 0
    fi
    try_refresh periodic
}

run_loop() {
    # Single instance: hold the lock for the whole lifetime.
    exec 8>"$LOCK" || exit 3
    flock -n 8 8>&8 || exit 0
    printf '%s\n' "$$" >"$PID_FILE" 2>/dev/null
    log "softreboot-watch: start pid=$$ interval=${INTERVAL}s max_attempts=$MAX_ATTEMPTS"
    i=0
    while :; do
        i=$((i + 1))
        if [ "$MODULE_EMBEDDED" = 1 ]; then
            require_owner_enabled && require_owner_mutation || {
                log 'softreboot-watch: owner_unavailable; stop'
                return 3
            }
        fi
        boot=$(boot_id 2>/dev/null)
        ss=$(ss_pid)
        if [ -z "$boot" ] || [ -z "$ss" ]; then
            sleep "$INTERVAL"
            continue
        fi
        handle_change "$boot" "$ss"
        now=$(date +%s 2>/dev/null)
        case "$now" in ''|*[!0-9]*) now=0 ;; esac
        if [ "$CHECK_INTERVAL" -gt 0 ] && [ "$now" -ge $((last_check + CHECK_INTERVAL)) ] 2>/dev/null; then
            last_check=$now
            integrity_check
            sh "$MODDIR/bin/status-card.sh" "$MODDIR" update 8>&- >/dev/null 2>&1 || :
        fi
        if [ "$ITERATIONS" != 0 ] && [ "$i" -ge "$ITERATIONS" ]; then
            break
        fi
        sleep "$INTERVAL"
    done
    log "softreboot-watch: stop iterations=$i"
}

start_daemon() {
    [ "${ENABLE_6G:-0}" = 1 ] || exit 0
    require_owner_enabled || exit 0
    if [ -f "$PID_FILE" ] && [ ! -L "$PID_FILE" ]; then
        old=$(cat "$PID_FILE" 2>/dev/null)
        case "$old" in
            ''|*[!0-9]*) ;;
            *) kill -0 "$old" 2>/dev/null && exit 0 ;;
        esac
    fi
    ( setsid sh "$MODDIR/bin/softreboot-watch.sh" "$MODDIR" run </dev/null >/dev/null 2>&1 & ) &
    exit 0
}

case "$MODE" in
    run) run_loop ;;
    start) start_daemon ;;
    *) echo 'usage: softreboot-watch.sh MODDIR [run|start]' >&2; exit 64 ;;
esac
