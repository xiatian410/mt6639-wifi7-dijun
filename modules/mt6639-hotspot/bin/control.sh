#!/system/bin/sh
# Explicit KernelSU action controller for the native EHT hotspot experiment.
set -u
umask 077
MODDIR=${1:-/data/adb/modules/mt6639-hotspot}
OP=${2:-status}
ARG_BAND=${3:-}
ARG_WIDTH=${4:-}
case "$MODDIR" in /data/adb/modules/mt6639-hotspot) ;; *) exit 64 ;; esac
[ -d "$MODDIR" ] && [ ! -L "$MODDIR" ] || exit 66
[ "$(id -u)" = 0 ] && [ "$(id -Z)" = u:r:ksu:s0 ] || exit 77
# kernel-adjacent callers (service.sh, action.sh, the Settings worker) start with
# only PATH set; app_process needs the Android runtime environment. Guard the
# source: '.' is a special builtin, so a missing file aborts a non-interactive
# shell rather than falling through.
if [ -f "$MODDIR/bin/android-env.sh" ] && [ ! -L "$MODDIR/bin/android-env.sh" ]; then
    . "$MODDIR/bin/android-env.sh"
fi

WORK=/data/adb/mt6639-hotspot
PRIVATE=$WORK/private
SESSION=$WORK/session
TASK_FILE=$SESSION/task
PID_FILE=$SESSION/pid
RUN_START_FILE=$SESSION/runner.start
BOOT_FILE=$SESSION/boot
BAND_FILE=$SESSION/band
WIDTH_FILE=$SESSION/width
STATE_FILE=$WORK/state
LOG=$WORK/control.log
rc=0

# Direct worker/UI starts must obey the same single-module reboot barrier.
# Recovery and explicit stop remain available when the guard rejects a start.
case "$OP" in
    start|toggle|c02-24g)
        [ -f "$MODDIR/bin/unified-guard.sh" ] && [ ! -L "$MODDIR/bin/unified-guard.sh" ] || {
            echo 'REJECT unified_guard_unavailable' >&2; exit 69; }
        sh "$MODDIR/bin/unified-guard.sh" "$MODDIR" check || exit $? ;;
esac

# This entry can run independently of request_worker.sh. Validate before any
# chmod, log, lock or session access; never follow an inherited work symlink.
work_parent=${WORK%/*}
[ -d "$work_parent" ] && [ ! -L "$work_parent" ] &&
    [ "$(stat -c %u "$work_parent")" = 0 ] || exit 77
[ ! -L "$WORK" ] || exit 77
if [ ! -e "$WORK" ]; then mkdir -m 0700 "$WORK" || exit 74; fi
[ -d "$WORK" ] && [ "$(stat -c %u "$WORK")" = 0 ] || exit 77
work_original_mode=$(stat -c %a "$WORK") || exit 77
chmod 0700 "$WORK" || exit 74
[ "$(stat -c %a "$WORK")" = 700 ] || exit 77
log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
    printf '%s\n' "$*"
}
publish_status() {
    sh "$MODDIR/bin/status_snapshot.sh" "$MODDIR" publish "$@" >/dev/null
}
boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }
sha_ok() { sh "$MODDIR/bin/verify-module.sh" "$MODDIR"; }
session_task() {
    [ ! -L "$TASK_FILE" ] && [ -f "$TASK_FILE" ] && [ -s "$TASK_FILE" ] || return 1
    task=$(cat "$TASK_FILE") || return 1
    case "$task" in /data/local/tmp/mt6639-native-ap-*) ;; *) return 2 ;; esac
    case "$task" in *[!a-zA-Z0-9/_-]*|*/../*|*/./*|*//*) return 2 ;; esac
    [ -d "$task" ] && [ ! -L "$task" ] && [ "$(stat -c %u "$task")" = 0 ] || return 2
    printf '%s\n' "$task"
}
runner_alive() {
    task=$(session_task) || return 1
    same_boot || return 1
    [ ! -L "$PID_FILE" ] && [ -f "$PID_FILE" ] || return 1
    pid=$(cat "$PID_FILE" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] && kill -0 "$pid" 2>/dev/null || return 1
    [ ! -L "$RUN_START_FILE" ] && [ -f "$RUN_START_FILE" ] || return 1
    [ "$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = \
        "$(cat "$RUN_START_FILE" 2>/dev/null)" ] || return 1
    # /proc/<pid>/cmdline reads can block on a wedged process; bound them so a
    # start never hangs in the "starting" state.
    cmd=$(timeout 2 tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || return 1
    case "$cmd" in *"$task/softap_native_once.sh"*"$task"*) return 0 ;; esac
    return 1
}
guardian_alive() {
    task=$(session_task) || return 1
    same_boot || return 1
    [ ! -L "$task/guardian.pid" ] && [ -f "$task/guardian.pid" ] || return 1
    [ ! -L "$task/guardian.start" ] && [ -f "$task/guardian.start" ] || return 1
    pid=$(cat "$task/guardian.pid" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] && kill -0 "$pid" 2>/dev/null || return 1
    [ "$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = \
        "$(cat "$task/guardian.start" 2>/dev/null)" ] || return 1
    cmd=$(timeout 2 tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || return 1
    case "$cmd" in *"$task"*guardian*) return 0 ;; esac
    return 1
}
guardian_process_without_record() {
    task=$(session_task) || return 0
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        cmd=$(timeout 2 tr '\000' ' ' < "$p/cmdline" 2>/dev/null) || continue
        case "$cmd" in *"$task"*guardian*) return 0 ;; esac
    done
    return 1
}
native_alive() {
    task=$(session_task) || return 1
    [ ! -L "$task/native.pid" ] && [ -f "$task/native.pid" ] || return 1
    [ ! -L "$task/native.start" ] && [ -f "$task/native.start" ] || return 1
    pid=$(cat "$task/native.pid" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] && kill -0 "$pid" 2>/dev/null || return 1
    [ "$(readlink "/proc/$pid/exe" 2>/dev/null)" = "$task/hostapd" ] || return 1
    [ "$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = \
        "$(cat "$task/native.start" 2>/dev/null)" ] || return 1
}
same_boot() {
    [ ! -L "$BOOT_FILE" ] && [ -f "$BOOT_FILE" ] &&
        [ "$(cat "$BOOT_FILE" 2>/dev/null)" = "$(boot_id)" ]
}
# Cross-kernel retirement is evidence-only: never use the same_boot-gated
# liveness helpers or execute a script from the obsolete task. Call only while
# holding action.lock. Every unknown observation retains the authority.
retirement_blocked() {
    printf 'REJECT cross_boot_retirement_blocked detail=%s\n' "$1" >&2
    return 78
}
retirement_dir_ok() {
    [ -d "$1" ] && [ ! -L "$1" ] &&
        [ "$(stat -c %u "$1")" = 0 ] && [ "$(stat -c %a "$1")" = 700 ]
}
retirement_file_ok() {
    [ -f "$1" ] && [ ! -L "$1" ] &&
        [ "$(stat -c %u "$1")" = 0 ] && [ "$(stat -c %a "$1")" = 600 ] &&
        [ "$(stat -c %h "$1")" = 1 ]
}
retirement_uuid_ok() {
    [ "${#1}" = 36 ] && printf '%s\n' "$1" |
        grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}
retirement_process_gone() {
    # Only disappearance of the entire PID entry excuses a failed read. A
    # missing child file, permission failure or PID reuse remains unknown.
    [ -d /proc/1 ] && [ -r /proc/1/cmdline ] &&
        [ ! -e "$cr_p" ] && [ ! -L "$cr_p" ]
}
retirement_no_processes() {
    # /proc enumeration is not a snapshot: short-lived processes (including
    # inspection helpers) may exit between glob expansion and any later read.
    [ -d /proc/1 ] && [ -r /proc/1/cmdline ] || return 1
    cr_seen=0
    for cr_p in /proc/[0-9]*; do
        if [ ! -d "$cr_p" ] || [ ! -r "$cr_p/cmdline" ]; then
            retirement_process_gone && continue
            return 1
        fi
        if ! cr_cmd=$( { timeout 2 tr '\000' ' ' < "$cr_p/cmdline"; } 2>/dev/null); then
            retirement_process_gone && continue
            return 1
        fi
        cr_seen=1
        case "$cr_cmd" in
            *softap_native_once.sh*|*hostapd*|*"$cr_task"*) return 1 ;;
        esac
        if cr_exe=$(timeout 2 readlink "$cr_p/exe" 2>/dev/null); then
            case "$cr_exe" in *hostapd*|*"$cr_task"*) return 1 ;; esac
        else
            retirement_process_gone && continue
            # Only a positively identified kernel thread may lack an executable
            # and command line. Existing zombies/read failures remain unknown.
            [ -z "$cr_cmd" ] || return 1
            if ! cr_flags=$(timeout 2 awk '{ sub(/^.*\) /, ""); print $7 }' "$cr_p/stat" 2>/dev/null); then
                retirement_process_gone && continue
                return 1
            fi
            case "$cr_flags" in ''|*[!0-9]*) return 1 ;; esac
            [ "$((cr_flags & 2097152))" != 0 ] || return 1
        fi
    done
    [ "$cr_seen" = 1 ]
}
retirement_tether_idle() {
    # Capture status independently: a failing dumpsys that prints an idle line
    # must not be accepted. Require both known idle fields exactly once; reject
    # mtap traces, serving states, malformed/contradictory fields and errors.
    cr_tether=$(timeout 5 dumpsys tethering --short 2>/dev/null) || return 1
    printf '%s\n' "$cr_tether" | awk '
        /mtap|TetheredState|LocalHotspotState/ { bad=1 }
        /[Ee][Rr][Rr][Oo][Rr]|[Ee]xception|[Ff]ailure|[Dd]enied/ { bad=1 }
        /Upstream wanted:/ {
            if ($0 ~ /^[[:space:]]*Upstream wanted: false$/) wanted++
            else bad=1
        }
        /Current upstream interface\(s\):/ {
            if ($0 ~ /^[[:space:]]*Current upstream interface\(s\): null$/) upstream++
            else bad=1
        }
        END { exit !(wanted == 1 && upstream == 1 && !bad) }
    '
}
retire_cross_boot_session() {
    [ "$work_original_mode" = 700 ] && retirement_dir_ok "$WORK" &&
        retirement_dir_ok "$SESSION" || { retirement_blocked authority_directory; return 78; }
    # Preserve even unknown extra records, but do not move links or special files
    # into history. All authority files must have remained private.
    for cr_f in "$SESSION"/* "$SESSION"/.[!.]* "$SESSION"/..?*; do
        [ -e "$cr_f" ] || [ -L "$cr_f" ] || continue
        retirement_file_ok "$cr_f" || { retirement_blocked authority_file; return 78; }
    done
    retirement_file_ok "$BOOT_FILE" && retirement_file_ok "$TASK_FILE" || {
        retirement_blocked missing_authority; return 78; }
    cr_old_boot=$(cat "$BOOT_FILE") && cr_boot=$(boot_id) &&
        retirement_uuid_ok "$cr_old_boot" && retirement_uuid_ok "$cr_boot" || {
        retirement_blocked boot_invalid; return 78; }
    [ "$cr_old_boot" != "$cr_boot" ] || { retirement_blocked same_boot; return 78; }
    cr_task=$(cat "$TASK_FILE") || { retirement_blocked task_unreadable; return 78; }
    case "$cr_task" in
        /data/local/tmp/mt6639-native-ap-?*) ;;
        *) retirement_blocked task_invalid; return 78 ;;
    esac
    cr_name=${cr_task#/data/local/tmp/}
    case "$cr_name" in *[!a-zA-Z0-9_-]*) retirement_blocked task_invalid; return 78 ;; esac
    # A reboot may remove /data/local/tmp tasks. Only their path is needed for
    # process matching. Existing task directories must still be private, and
    # none of their ancestors may redirect the authority through a symlink.
    for cr_d in /data /data/local /data/local/tmp; do
        [ -d "$cr_d" ] && [ ! -L "$cr_d" ] || { retirement_blocked task_parent; return 78; }
    done
    if [ -e "$cr_task" ] || [ -L "$cr_task" ]; then
        retirement_dir_ok "$cr_task" || { retirement_blocked task_directory; return 78; }
    fi
    for cr_f in "$STATE_FILE" "$LOG"; do
        if [ -e "$cr_f" ] || [ -L "$cr_f" ]; then
            retirement_file_ok "$cr_f" || { retirement_blocked output_path; return 78; }
        fi
    done
    if [ -e "$WORK/history" ] || [ -L "$WORK/history" ]; then
        retirement_dir_ok "$WORK/history" || { retirement_blocked history_path; return 78; }
    fi
    # Successful enumeration, not a failed per-interface lookup, proves absence.
    cr_links=$(timeout 5 ip -o link show 2>/dev/null) || {
        retirement_blocked interface_query; return 78; }
    printf '%s\n' "$cr_links" | awk '
        !/^[0-9]+: [^:]+: / { bad=1 }
        /^[0-9]+: mtap[^:]*:/ { bad=1 }
        /^[0-9]+: lo: / { loopback=1 }
        END { exit !(loopback && !bad) }
    ' || { retirement_blocked interface_present_or_unknown; return 78; }
    for cr_net in /sys/class/net/mtap*; do
        [ ! -e "$cr_net" ] && [ ! -L "$cr_net" ] || {
            retirement_blocked interface_present; return 78; }
    done
    retirement_no_processes || { retirement_blocked process_present_or_unknown; return 78; }
    retirement_tether_idle || { retirement_blocked tether_active_or_unknown; return 78; }
    # Rename the entire session into a newly reserved destination on the same
    # filesystem. No copy-and-delete, no task/key cleanup, no overwritten history.
    if [ ! -e "$WORK/history" ]; then
        mkdir -m 0700 "$WORK/history" || return 74
    fi
    cr_session_dev=$(stat -c %d "$SESSION") &&
        cr_history_dev=$(stat -c %d "$WORK/history") &&
        [ -n "$cr_session_dev" ] && [ "$cr_session_dev" = "$cr_history_dev" ] || return 74
    cr_archive=$(mktemp -d "$WORK/history/cross-boot.XXXXXXXX") || return 74
    cr_state=$(mktemp "$WORK/.retired-state.XXXXXXXX") || return 74
    if ! printf '%s\n' idle > "$cr_state" ||
        ! mv "$SESSION" "$cr_archive/session"; then
        rm -f "$cr_state"
        return 74
    fi
    if ! mv -f "$cr_state" "$STATE_FILE"; then
        # Keep explicit stop/reconcile retryable if local state publication fails.
        # Even if rollback itself fails, the complete authority remains archived.
        mv "$cr_archive/session" "$SESSION" || {
            printf '%s\n' 'REJECT cross_boot_retirement_blocked detail=archive_rollback_failed' >&2
        }
        rm -f "$cr_state"
        return 74
    fi
    publish_status idle none none || true
    printf '%s\n' 'state=idle retired=1 reason=cross_boot_session_retired'
}
reconcile_session() {
    [ -e "$SESSION" ] || [ -L "$SESSION" ] || return 0
    retire_cross_boot_session
}

clear_session() {
    [ ! -L "$SESSION" ] && { [ ! -e "$SESSION" ] || [ -d "$SESSION" ]; } || return 1
    if [ -d "$SESSION" ]; then
        archive=$WORK/history/$(date +%Y%m%d-%H%M%S)-$$
        mkdir -p "$archive" || return 1
        cp -p "$SESSION"/* "$archive"/ 2>/dev/null || true
    fi
    printf '%s\n' idle > "$STATE_FILE" || return 1
    rm -f "$TASK_FILE" "$PID_FILE" "$RUN_START_FILE" "$BOOT_FILE" "$BAND_FILE" "$WIDTH_FILE" || return 1
    rmdir "$SESSION" 2>/dev/null || true
}
active_checked() {
    runner_alive || return 1
    guardian_alive || return 1
    native_alive || return 1
    task=$(session_task) || return 1
    band=$(cat "$BAND_FILE" 2>/dev/null)
    width=$(cat "$WIDTH_FILE" 2>/dev/null)
    case "$band:$width" in
        2g:20|5g:20|5g:40|5g:80|6g:20|6g:40|6g:80|6g:160|6g:320) ;;
        *) return 1 ;;
    esac
    tmp=$task/status.recheck.$$
    timeout 5 "$task/hostapd_cli" -p "$task/ctrl" -i mtap0 status > "$tmp" 2>&1 || {
        rm -f "$tmp"
        return 1
    }
    grep -Fxq state=ENABLED "$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$task/status.active" || return 1
    sh "$task/softap_native_config.sh" "$task" status "$band" "$width" >/dev/null 2>&1 || return 1
    timeout 5 dumpsys tethering --short 2>/dev/null |
        grep -Eq '^[[:space:]]*mtap0 - TetheredState - lastError = 0$'
}

# A recorded recovery failure used to be replayed verbatim on every later
# start/stop, so one transient error (the station check losing the
# re-association race, or a checker that pinned an old module version) locked the
# module until reboot. Retry the checked recovery itself: bounded per boot,
# rate-limited, and each failed result is archived instead of overwritten.
retry_checked_recovery() {
    task=$1
    [ -f "$task/recovery.rc" ] && [ ! -L "$task/recovery.rc" ] || return 1
    limit=${MT6639_RECOVERY_RETRIES:-2}
    cooldown=${MT6639_RECOVERY_COOLDOWN:-20}
    n=$(cat "$task/recovery.retries" 2>/dev/null || printf 0)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    [ "$n" -lt "$limit" ] || { log "REJECT recovery_retries_exhausted n=$n"; return 1; }
    now=$(date +%s 2>/dev/null)
    case "$now" in ''|*[!0-9]*) now=0 ;; esac
    mtime=$(stat -c %Y "$task/recovery.rc" 2>/dev/null || printf 0)
    case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
    if [ "$now" -gt 0 ] && [ "$mtime" -gt 0 ] &&
        [ "$now" -ge "$mtime" ] && [ $((now - mtime)) -lt "$cooldown" ]; then
        log "REJECT recovery_cooldown remaining=$((cooldown - (now - mtime)))s"
        return 1
    fi
    n=$((n + 1))
    printf '%s\n' "$n" > "$task/recovery.retries" || return 1
    mv "$task/recovery.rc" "$task/recovery.failed.$n" 2>/dev/null || return 1
    log "retry_checked_recovery attempt=$n/$limit"
    timeout -s KILL 120 sh "$task/softap_native_once.sh" "$task" recover \
        > "$task/control.recover.$n" 2>&1 || {
        log 'REJECT recovery_command_failed_retry'
        return 1
    }
    [ -s "$task/recovery.rc" ] || { log 'REJECT recovery_result_missing_retry'; return 1; }
    [ "$(cat "$task/recovery.rc" 2>/dev/null)" = 0 ]
}

stop_session() {
    if [ -e "$SESSION" ] || [ -L "$SESSION" ]; then
        [ -d "$SESSION" ] && [ ! -L "$SESSION" ] || {
            retirement_blocked authority_directory; return 78; }
        cr_current_boot=$(boot_id) && retirement_uuid_ok "$cr_current_boot" || {
            retirement_blocked boot_invalid; return 78; }
        if ! same_boot; then
            retire_cross_boot_session
            return $?
        fi
    fi
    if task=$(session_task); then
        :
    else
        s=$?
        [ "$s" = 1 ] && { clear_session || return 70; return 0; }
        log 'REJECT session_task_invalid; authority retained'
        return 73
    fi
    same_boot || { log 'REJECT session_cross_boot; authority retained'; return 78; }
    publish_status stopping "$(cat "$BAND_FILE" 2>/dev/null || printf none)" \
        "$(cat "$WIDTH_FILE" 2>/dev/null || printf none)" || true
    if [ ! -e "$task/cleanup.request" ]; then
        : > "$task/cleanup.request" || { log 'REJECT cleanup_request_failed'; return 74; }
    fi
    i=0
    while [ "$i" -lt 90 ]; do
        running=0
        guarding=0
        runner_alive && running=1
        guardian_alive && guarding=1
        [ "$running" = 1 ] || [ "$guarding" = 1 ] || break
        sleep 1
        i=$((i+1))
    done
    if runner_alive; then
        log 'REJECT runner_still_alive_after_cleanup'
        return 73
    fi
    if guardian_alive || guardian_process_without_record; then
        log 'REJECT guardian_still_alive_after_cleanup'
        return 73
    fi
    # A process that died before the first driver/interface/tether intent is
    # restartable only when no effect marker and no mtap0 exist.
    if [ ! -e "$task/driver.intent" ] && [ ! -e "$task/interface.intent" ] &&
        [ ! -e "$task/tether.intent" ] && [ ! -e /sys/class/net/mtap0 ]; then
        clear_session || return 70
        echo 'state=idle restored=1 reason=no_effect_terminal'
        return 0
    fi
    if [ ! -s "$task/recovery.rc" ]; then
        log 'recovery_missing; invoking checked recover'
        timeout -s KILL 120 sh "$task/softap_native_once.sh" "$task" recover \
            > "$task/control.recover" 2>&1 || {
            log 'REJECT recovery_command_failed'
            return 73
        }
    fi
    if [ ! -s "$task/recovery.rc" ]; then
        log 'REJECT recovery_result_missing'
        return 73
    fi
    if [ "$(cat "$task/recovery.rc" 2>/dev/null)" != 0 ]; then
        retry_checked_recovery "$task" ||
            { log "REJECT recovery_rc=$(cat "$task/recovery.rc" 2>/dev/null)"; return 73; }
    fi
    [ ! -e /sys/class/net/mtap0 ] || { log 'REJECT interface_still_present'; return 73; }
    timeout 5 dumpsys tethering --short 2>/dev/null |
        grep -Eq '^[[:space:]]*mtap0 - (TetheredState|LocalHotspotState)' && {
            log 'REJECT tethering_still_active'; return 73; }
    action_rc=$(cat "$task/action.rc" 2>/dev/null || printf '%s\n' missing)
    clear_session || return 70
    publish_status idle none none || true
    echo "state=idle restored=1 action_rc=$action_rc"
}

discard_staged_task() {
    task=$1
    case "$task" in /data/local/tmp/mt6639-native-ap-*) ;; *) return 64 ;; esac
    [ -d "$task" ] && [ ! -L "$task" ] &&
        [ "$(stat -c %u "$task")" = 0 ] && [ "$(stat -c %a "$task")" = 700 ] || return 73
    if [ -f "$TASK_FILE" ] && [ "$(cat "$TASK_FILE" 2>/dev/null)" = "$task" ]; then
        return 75
    fi
    [ ! -e "$task/guardian.pid" ] && [ ! -e "$task/native.pid" ] || return 73
    rm -f "$task/softap_native_once.sh" "$task/softap_native_config.sh" \
        "$task/ssid_hex.sh" "$task/ap.ssid.hex" \
        "$task/hostapd" "$task/hostapd_cli" "$task/delete_ifindex" \
        "$task/native-tether.dex" "$task/softap-profile.dex" \
        "$task/twt_recover.sh" "$task/hotspot-identity.sh" "$task/hotspot-upstream.sh" \
        "$task/compat.sh" "$task/compatibility.conf" "$task/ap.key" "$task/reconnect.key" \
        "$task/reconnect-2g.key" "$task/ap.conf" "$task/.stage-error" || return 74
    rmdir "$task" || return 76
}

stage_native_task() {
    task=$1 upstream_key=$2
    for f in softap_native_once.sh softap_native_config.sh ssid_hex.sh hostapd hostapd_cli \
        delete_ifindex native-tether.dex softap-profile.dex twt_recover.sh \
        hotspot-identity.sh hotspot-upstream.sh compat.sh compatibility.conf; do
        cp "$MODDIR/bin/$f" "$task/$f" || {
            printf 'stage_failed_%s\n' "$f" > "$task/.stage-error"
            return 70
        }
    done
    cp "$PRIVATE/ap.key" "$task/ap.key" || {
            printf 'private_stage_failed\n' > "$task/.stage-error"
            return 70
        }
    # Capture a validated preference once. Later edits affect only new tasks.
    if [ -e "$PRIVATE/ap.ssid.hex" ] || [ -L "$PRIVATE/ap.ssid.hex" ]; then
        p=$PRIVATE/ap.ssid.hex
        if ! { [ -f "$p" ] && [ ! -L "$p" ] &&
            [ "$(stat -c %u "$p")" = 0 ] && [ "$(stat -c %a "$p")" = 600 ] &&
            [ "$(stat -c %s "$p")" -le 65 ] &&
            sh "$task/ssid_hex.sh" < "$p" > "$task/ap.ssid.hex" &&
            chmod 0600 "$task/ap.ssid.hex"; }; then
            printf 'name_stage_failed\n' > "$task/.stage-error"
            return 65
        fi
    fi
    if [ "$upstream_key" != none ]; then
        cp "$PRIVATE/$upstream_key" "$task/$upstream_key" || {
            printf 'private_stage_failed\n' > "$task/.stage-error"
            return 70
        }
    fi
    chmod 0700 "$task"/*.sh "$task/hostapd" "$task/hostapd_cli" "$task/delete_ifindex" &&
        chmod 0600 "$task"/*.key "$task"/*.dex || {
            printf 'stage_permission_failed\n' > "$task/.stage-error"
            return 70
        }
    if ! sh "$task/softap_native_config.sh" "$task" render "$band" "$width" \
        > "$task/ap.conf"; then
        printf 'config_render_failed\n' > "$task/.stage-error"
        return 69
    fi
    sh "$task/softap_native_config.sh" "$task" check "$band" "$width" >/dev/null 2>&1 || {
        printf 'config_check_failed\n' > "$task/.stage-error"
        return 69
    }
}

abort_staged_start() {
    task=$1 reason=$2 code=$3
    log "REJECT staged_start_$reason"
    # Only publication failures after this attempt's successful mkdir own it.
    # In particular, a failed mkdir must preserve the pre-existing session.
    if [ "${4:-0}" = 1 ] && { [ -e "$SESSION" ] || [ -L "$SESSION" ]; }; then
        clear_session || log 'REJECT staged_session_cleanup_failed'
    fi
    if [ -d "$task" ]; then
        discard_staged_task "$task" ||
            log "REJECT staged_task_cleanup_failed reason=$reason"
    fi
    return "$code"
}

start_session() {
    . "$MODDIR/config.conf"
    band=${ARG_BAND:-${BAND:-6g}}
    width=${ARG_WIDTH:-${WIDTH:-20}}
    hold=${GUARDIAN_HOLD_SECONDS:-86400}
    case "$band:$width" in
        2g:20|5g:20|5g:40|5g:80|6g:20|6g:40|6g:80|6g:160|6g:320) ;;
        *)
        log 'REJECT unsupported_band_width'; return 64 ;; esac
    case "$hold" in ''|*[!0-9]*) return 64 ;; esac
    [ "$hold" -ge 30 ] && [ "$hold" -le 86400 ] || return 64
    [ "$(getenforce)" = Enforcing ] || { log 'REJECT enforcing_required'; return 77; }
    android_env_ready || { log 'REJECT android_env_unavailable'; return 69; }
    if [ -e "$MODDIR/disable" ] || [ -e "$MODDIR/remove" ]; then
        log 'REJECT module_disabled_or_removing'
        return 73
    fi
    sha_ok || { log 'REJECT module_asset_hash_mismatch'; return 69; }
    # AP credentials are always required, before any identity/status work.
    f=ap.key
    p=$PRIVATE/$f
    [ -d "$PRIVATE" ] && [ ! -L "$PRIVATE" ] && [ -f "$p" ] && [ ! -L "$p" ] &&
        [ "$(stat -c %u "$p")" = 0 ] && [ "$(stat -c %a "$p")" = 600 ] || {
            log "REJECT private_file_invalid $f"; return 66; }
    identity=$(sh "$MODDIR/bin/hotspot-identity.sh" "$MODDIR/bin" 2>&1) || {
        log "$identity"; return 69;
    }
    log "$identity"
    upstream_mode=$(sh "$MODDIR/bin/hotspot-upstream.sh" "${MT6639_HOTSPOT_UPSTREAM:-auto}" "$band") || {
        log 'REJECT upstream_preflight_failed'; return 69;
    }
    upstream_key=none
    if [ "$upstream_mode" = wifi ]; then
        case "$band" in
            2g|5g) upstream_key=reconnect-2g.key ;;
            6g) upstream_key=reconnect.key ;;
        esac
    fi
    if [ "$upstream_key" != none ]; then
        f=$upstream_key
        p=$PRIVATE/$f
        [ -d "$PRIVATE" ] && [ ! -L "$PRIVATE" ] && [ -f "$p" ] && [ ! -L "$p" ] &&
            [ "$(stat -c %u "$p")" = 0 ] && [ "$(stat -c %a "$p")" = 600 ] || {
                log "REJECT private_file_invalid $f"; return 66; }
    fi
    if [ -e "$TASK_FILE" ]; then
        if active_checked; then log 'state=already_active'; return 0; fi
        stop_session || return $?
    fi
    [ ! -e /sys/class/net/mtap0 ] || { log 'REJECT mtap0_exists'; return 73; }
    timeout 5 dumpsys tethering --short 2>/dev/null |
        grep -Fxq '    Upstream wanted: false' || {
            log 'REJECT tethering_not_idle'; return 73; }
    publish_status starting "$band" "$width" || true

    b=$(boot_id) || return 70
    task=$(mktemp -d "/data/local/tmp/mt6639-native-ap-${b%%-*}-${hold}-XXXXXX") || return 70
    chmod 0700 "$task" || {
        abort_staged_start "$task" task_chmod 70
        return 70
    }
    stage_rc=0
    stage_native_task "$task" "$upstream_key" || stage_rc=$?
    if [ "$stage_rc" != 0 ]; then
        reason=$(cat "$task/.stage-error" 2>/dev/null || printf 'staging_failed\n')
        abort_staged_start "$task" "$reason" "$stage_rc"
        return "$stage_rc"
    fi
    if ! mkdir "$SESSION"; then
        abort_staged_start "$task" session_mkdir 73
        return 73
    fi
    if ! printf '%s\n' "$task" > "$TASK_FILE" ||
        ! printf '%s\n' "$b" > "$BOOT_FILE" ||
        ! printf '%s\n' "$band" > "$BAND_FILE" ||
        ! printf '%s\n' "$width" > "$WIDTH_FILE" ||
        ! printf '%s\n' starting > "$STATE_FILE"; then
        abort_staged_start "$task" session_publish 70 1
        return 70
    fi
    MT6639_HOTSPOT_UPSTREAM=$upstream_mode \
        MODULE_GUARD_DIR=$MODDIR GUARDIAN_HOLD_SECONDS=$hold nohup setsid sh \
        "$task/softap_native_once.sh" "$task" run-tether "$band" "$width" \
        > "$task/session.log" 2>&1 < /dev/null &
    pid=$!
    printf '%s\n' "$pid" > "$PID_FILE" || return 70
    awk '{print $22}' "/proc/$pid/stat" > "$RUN_START_FILE" || return 70
    i=0
    while [ "$i" -lt 100 ]; do
        if ! runner_alive; then
            if [ -f "$task/failure" ] && [ ! -L "$task/failure" ]; then
                log "REJECT runner_exited_during_start reason=$(timeout 2 tr -d '\n' < "$task/failure")"
            else
                log 'REJECT runner_exited_during_start reason=unreported'
            fi
            # A runner that gave up after running its own checked teardown leaves
            # a terminal recovery.rc=0; one that rejected a precondition never
            # touched the driver at all. Both are terminal, so close the session
            # here instead of leaving the module in 'starting' until somebody
            # runs stop by hand.
            start_no_effect=0
            if [ ! -e "$task/driver.intent" ] && [ ! -e "$task/interface.intent" ] &&
                [ ! -e "$task/tether.intent" ] && [ ! -e /sys/class/net/mtap0 ]; then
                start_no_effect=1
            fi
            if [ "$start_no_effect" = 1 ] ||
                { [ "$(cat "$task/recovery.rc" 2>/dev/null)" = 0 ] &&
                  [ ! -e /sys/class/net/mtap0 ]; }; then
                failed_action_rc=$(cat "$task/action.rc" 2>/dev/null || printf 'missing')
                if clear_session; then
                    log "state=idle restored=1 action_rc=$failed_action_rc"
                else
                    log 'REJECT session_clear_failed'
                fi
            fi
            return 71
        fi
        if active_checked; then
            printf '%s\n' active > "$STATE_FILE"
            publish_status active "$band" "$width" || true
            log "state=active task=$task pid=$pid band=$band width=$width hold=$hold"
            return 0
        fi
        sleep 1
        i=$((i+1))
    done
    log 'REJECT start_timeout; requesting checked cleanup'
    publish_status unresolved "$band" "$width" || true
    : > "$task/cleanup.request" 2>/dev/null || true
    return 72
}

run_c02_24g() {
    . "$MODDIR/config.conf"
    android_env_ready || { log 'REJECT android_env_unavailable'; return 69; }
    [ ! -e "$TASK_FILE" ] || { log 'REJECT native_session_exists'; return 73; }
    [ ! -e /sys/class/net/mtap0 ] || { log 'REJECT mtap0_exists'; return 73; }
    [ ! -e "$MODDIR/disable" ] && [ ! -e "$MODDIR/remove" ] ||
        { log 'REJECT module_disabled_or_removing'; return 73; }
    sha_ok || { log 'REJECT module_asset_hash_mismatch'; return 69; }
    publish_status starting 2g 20 || true
    output=$(MT6639_C02_FORCE_AX=${MT6639_C02_FORCE_AX:-0} \
        sh "$MODDIR/bin/softap_24g_once.sh" "$MODDIR")
    rc=$?
    [ -z "$output" ] || printf '%s\n' "$output"
    if [ "$rc" = 0 ]; then
        publish_status idle none none || true
    else
        publish_status unresolved 2g 20 || true
    fi
    return "$rc"
}

status() {
    echo "boot=$(boot_id)"
    module_state=$( [ -e "$MODDIR/disable" ] && echo disabled || echo enabled )
    echo "module=$module_state"
    if [ "$module_state" = disabled ]; then
        publish_status disabled none none || true
    fi
    if task=$(session_task); then
        if active_checked; then state=active; else state=unresolved; fi
        display_band=$(cat "$BAND_FILE" 2>/dev/null || printf none)
        display_width=$(cat "$WIDTH_FILE" 2>/dev/null || printf none)
        [ "$module_state" = disabled ] || publish_status "$state" "$display_band" "$display_width" || true
        echo "state=$state"
        echo "task=$task"
        echo "same_boot=$(same_boot && echo 1 || echo 0)"
        echo "runner=$(runner_alive && echo alive || echo not_running)"
        echo "guardian=$(guardian_alive && echo alive || echo not_running)"
        echo "action_rc=$(cat "$task/action.rc" 2>/dev/null || echo pending)"
        echo "recovery_rc=$(cat "$task/recovery.rc" 2>/dev/null || echo pending)"
        [ -s "$task/status.active" ] && grep -E '^(state|freq|channel|ieee80211be|eht_oper_chwidth)=' "$task/status.active"
    else
        s=$?
        [ "$s" = 1 ] || { echo session_task=invalid; return 73; }
        state=$(cat "$STATE_FILE" 2>/dev/null || echo idle)
        case "$state" in starting|active|stopping|unresolved) ;; *) state=idle ;; esac
        [ "$module_state" = disabled ] || publish_status "$state" none none || true
        echo "state=$state"
        echo task=none
    fi
}

action_lock() {
    if [ -e "$WORK/action.lock" ] || [ -L "$WORK/action.lock" ]; then
        retirement_file_ok "$WORK/action.lock" || return 77
    fi
    exec 7>>"$WORK/action.lock" || return 70
    flock -n 7 7>&7 || return 75
}

case "$OP" in
    start|stop|recover|toggle|c02-24g|reconcile)
        if action_lock; then
            :
        else
            lock_rc=$?
            printf '%s\n' 'REJECT action_busy' >&2
            exit "$lock_rc"
        fi
        ;;
esac

case "$OP" in
    reconcile)
        reconcile_session
        rc=$?
        ;;
    status)
        status
        rc=$?
        ;;
    start)
        start_session
        rc=$?
        if [ "$rc" != 0 ]; then
            # A fail-closed rejection creates nothing; publishing "unresolved"
            # leaves Settings stuck on an unknown state. Echo the controller's
            # own state, and reserve "unresolved" for a leftover session.
            if session_task >/dev/null; then
                publish_status unresolved "${ARG_BAND:-none}" "${ARG_WIDTH:-none}" || true
            else
                state_now=$(cat "$STATE_FILE" 2>/dev/null || printf idle)
                case "$state_now" in
                    starting|active|stopping|unresolved)
                        publish_status unresolved "${ARG_BAND:-none}" "${ARG_WIDTH:-none}" || true ;;
                    *)
                        publish_status idle none none || true ;;
                esac
            fi
        fi
        ;;
    c02-24g)
        run_c02_24g
        rc=$?
        ;;
    stop|recover)
        stop_session
        rc=$?
        [ "$rc" = 0 ] || publish_status unresolved \
            "$(cat "$BAND_FILE" 2>/dev/null || printf none)" \
            "$(cat "$WIDTH_FILE" 2>/dev/null || printf none)" || true
        ;;
    toggle)
        if active_checked; then stop_session; else start_session; fi
        rc=$?
        [ "$rc" = 0 ] || publish_status unresolved "${ARG_BAND:-none}" "${ARG_WIDTH:-none}" || true
        ;;
    *) echo 'usage: control.sh MODDIR status|reconcile|start|stop|recover|toggle [5g|6g WIDTH]|c02-24g' >&2; exit 64 ;;
esac
case "$OP" in
    start|stop|recover|toggle|c02-24g)
        timeout 3 sh "$MODDIR/bin/status-card.sh" "$MODDIR" update "$OP" "$rc" >/dev/null 2>&1 || true
        ;;
esac
exit "$rc"
