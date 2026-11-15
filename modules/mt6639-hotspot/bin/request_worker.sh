#!/system/bin/sh
# Narrow system_app -> KSU request bridge for the experimental hotspot.
# Only fixed start(6g/20) and stop requests are accepted. No arbitrary command,
# band, width, shell fragment, or caller-supplied path is executed.
set -u
umask 077

MODDIR=${1:-/data/adb/modules/mt6639-hotspot}
OP=${2:-once}
case "$MODDIR" in /data/adb/modules/mt6639-hotspot) ;; *) exit 64 ;; esac
case "$OP" in start|run|stop|status|once) ;; *) exit 64 ;; esac

WORK=/data/adb/mt6639-hotspot
BRIDGE=$WORK/bridge
PID_FILE=$BRIDGE/worker.pid
START_FILE=$BRIDGE/worker.start
BOOT_FILE=$BRIDGE/worker.boot
# Settings on this build keeps its files dir in device-protected storage
# (/data/user_de/0), so accept either location. Both are validated below for
# owner, group, mode and label, so widening the path does not widen the trust
# boundary.
REQUEST_DIR=/data/user/0/com.android.settings/files/mt6639-hotspot
for candidate in \
    /data/user/0/com.android.settings/files/mt6639-hotspot \
    /data/user_de/0/com.android.settings/files/mt6639-hotspot; do
    if [ -d "$candidate" ] && [ ! -L "$candidate" ]; then
        REQUEST_DIR=$candidate
        break
    fi
done
CLAIM=$BRIDGE/claimed
REJECTED=$BRIDGE/rejected
RESULT=$BRIDGE/last-result
EXPECTED_UID=1000
EXPECTED_GID=1000
EXPECTED_LABEL=u:object_r:system_app_data_file:s0
MAX_AGE_SECONDS=60
MAX_FUTURE_SECONDS=5
ENTRY_SEQ=0

[ -d "$MODDIR" ] && [ ! -L "$MODDIR" ] || exit 66
# The worker is started by service.sh, whose environment only carries PATH.
# Export the Android runtime environment once so every dispatched control.sh
# (and the app_process calls it spawns) inherits it. Sourcing is guarded by an
# existence test: '.' is a POSIX special builtin, so a missing file would abort
# a non-interactive shell instead of returning to the '||' fallback.
if [ -f "$MODDIR/bin/android-env.sh" ] && [ ! -L "$MODDIR/bin/android-env.sh" ]; then
    . "$MODDIR/bin/android-env.sh"
fi

boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }
worker_alive() {
    [ -f "$PID_FILE" ] && [ ! -L "$PID_FILE" ] &&
        [ -f "$START_FILE" ] && [ ! -L "$START_FILE" ] &&
        [ -f "$BOOT_FILE" ] && [ ! -L "$BOOT_FILE" ] || return 1
    [ "$(cat "$BOOT_FILE" 2>/dev/null)" = "$(boot_id)" ] || return 1
    pid=$(cat "$PID_FILE" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] && kill -0 "$pid" 2>/dev/null || return 1
    [ "$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)" = \
        "$(cat "$START_FILE" 2>/dev/null)" ]
}
prepare_private() {
    work_parent=${WORK%/*}
    [ -d "$work_parent" ] && [ ! -L "$work_parent" ] &&
        [ "$(stat -c %u "$work_parent")" = 0 ] || exit 77
    if [ ! -e "$WORK" ] && [ ! -L "$WORK" ]; then
        mkdir -m 0700 "$WORK" || exit 74
    fi
    [ -d "$WORK" ] && [ ! -L "$WORK" ] &&
        [ "$(stat -c %u "$WORK")" = 0 ] &&
        [ "$(stat -c %a "$WORK")" = 700 ] || exit 77
    mkdir -p "$BRIDGE" "$CLAIM" "$REJECTED" || exit 74
    for d in "$BRIDGE" "$CLAIM" "$REJECTED"; do
        [ -d "$d" ] && [ ! -L "$d" ] && [ "$(stat -c %u "$d")" = 0 ] || exit 77
        chmod 0700 "$d" || exit 74
    done
}
request_dir_ready() {
    [ -d "$REQUEST_DIR" ] && [ ! -L "$REQUEST_DIR" ] || return 1
    [ "$(stat -c %u "$REQUEST_DIR")" = "$EXPECTED_UID" ] || return 1
    [ "$(stat -c %g "$REQUEST_DIR")" = "$EXPECTED_GID" ] || return 1
    [ "$(stat -c %a "$REQUEST_DIR")" = 700 ] || return 1
    [ "$(stat -c %C "$REQUEST_DIR" 2>/dev/null)" = "$EXPECTED_LABEL" ]
}
record_result() {
    result=$1
    nonce=${2:-none}
    rc=${3:-255}
    tmp=$RESULT.tmp.$$
    {
        printf 'boot=%s\n' "$(boot_id)"
        printf 'time=%s\n' "$(date +%s)"
        printf 'result=%s\n' "$result"
        printf 'nonce=%s\n' "$nonce"
        printf 'rc=%s\n' "$rc"
    } > "$tmp" || return 1
    chmod 0600 "$tmp" || return 1
    mv "$tmp" "$RESULT" || return 1
}
recover_claimed() {
    recovered=0
    for claimed in "$CLAIM"/*.req; do
        [ -e "$claimed" ] || [ -L "$claimed" ] || continue
        ENTRY_SEQ=$((ENTRY_SEQ + 1))
        seq=$(date +%s)-$$-$ENTRY_SEQ
        target=$REJECTED/$seq.interrupted_claim
        mv "$claimed" "$target" 2>/dev/null || continue
        if [ -e "$claimed.execute" ] || [ -L "$claimed.execute" ]; then
            mv "$claimed.execute" "$target.execute" 2>/dev/null || true
        fi
        record_result interrupted_claim unknown 255 || true
        recovered=$((recovered + 1))
    done
    for marker in "$CLAIM"/*.req.execute; do
        [ -e "$marker" ] || [ -L "$marker" ] || continue
        ENTRY_SEQ=$((ENTRY_SEQ + 1))
        seq=$(date +%s)-$$-$ENTRY_SEQ
        mv "$marker" "$REJECTED/$seq.orphan_execute" 2>/dev/null || continue
        record_result interrupted_claim unknown 255 || true
        recovered=$((recovered + 1))
    done
    [ "$recovered" = 0 ] || printf 'worker=recovered_interrupted_claims count=%s\n' "$recovered"
}
valid_nonce() {
    printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{32}$'
}
quarantine_entry() {
    source=$1
    reason=$2
    case "$source" in "$REQUEST_DIR"/request.*.req) ;; *) return 1 ;; esac
    ENTRY_SEQ=$((ENTRY_SEQ + 1))
    seq=$(date +%s)-$$-$ENTRY_SEQ
    target=$REJECTED/$seq.$reason
    mv "$source" "$target" 2>/dev/null || return 1
    record_result "rejected_$reason" invalid 77 || true
    return 0
}
validate_request() {
    file=$1
    now=$(date +%s) || return 1
    mtime=$(stat -c %Y "$file" 2>/dev/null) || return 1
    case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
    [ "$mtime" -le $((now + MAX_FUTURE_SECONDS)) ] || return 1
    [ $((now - mtime)) -le "$MAX_AGE_SECONDS" ] || return 1

    schema=; op=; band=; width=; request_boot=; request_nonce=
    while IFS='=' read -r key value; do
        case "$key:$value" in
            *:|*[![:print:]]*) return 1 ;;
        esac
        case "$key" in
            schema)
                [ -z "$schema" ] || return 1
                schema=$value
                ;;
            op)
                [ -z "$op" ] || return 1
                op=$value
                ;;
            band)
                [ -z "$band" ] || return 1
                band=$value
                ;;
            width)
                [ -z "$width" ] || return 1
                width=$value
                ;;
            boot)
                [ -z "$request_boot" ] || return 1
                request_boot=$value
                ;;
            nonce)
                [ -z "$request_nonce" ] || return 1
                request_nonce=$value
                ;;
            *) return 1 ;;
        esac
    done < "$file"

    [ "$schema" = mt6639-hotspot-request-v1 ] || return 1
    case "$op:$band:$width" in
        start:6g:20|start:6g:40|start:6g:80|start:6g:160|start:6g:320|\
        start:5g:20|start:5g:40|start:5g:80|start:2g:20|\
        c02-24g:6g:20|stop:6g:20) ;;
        *) return 1 ;;
    esac
    [ "$request_boot" = "$(boot_id)" ] || return 1
    valid_nonce "$request_nonce" || return 1
    REQUEST_OP=$op
    REQUEST_BAND=$band
    REQUEST_WIDTH=$width
    REQUEST_NONCE=$request_nonce
}
process_one() {
    request_dir_ready || return 1
    for candidate in "$REQUEST_DIR"/request.*.req; do
        [ "$candidate" = "$REQUEST_DIR/request.*.req" ] && break
        [ -e "$candidate" ] || [ -L "$candidate" ] || continue
        base=${candidate##*/}
        case "$base" in request.*.req) ;; *) continue ;; esac
        nonce=${base#request.}
        nonce=${nonce%.req}
        if ! valid_nonce "$nonce"; then
            quarantine_entry "$candidate" invalid_name || true
            continue
        fi

        ENTRY_SEQ=$((ENTRY_SEQ + 1))
        seq=$(date +%s)-$$-$ENTRY_SEQ
        claimed=$CLAIM/$seq.req
        mv "$candidate" "$claimed" || continue
        if [ -L "$claimed" ] || [ ! -f "$claimed" ]; then
            mv "$claimed" "$REJECTED/$seq.nonregular" 2>/dev/null || true
            record_result rejected_nonregular "$nonce" 77 || true
            continue
        fi
        size=$(stat -c %s "$claimed" 2>/dev/null)
        uid=$(stat -c %u "$claimed" 2>/dev/null)
        gid=$(stat -c %g "$claimed" 2>/dev/null)
        mode=$(stat -c %a "$claimed" 2>/dev/null)
        if [ "${size:-0}" -gt 512 ] || [ "$uid" != "$EXPECTED_UID" ] ||
            [ "$gid" != "$EXPECTED_GID" ] || [ "$mode" != 600 ]; then
            mv "$claimed" "$REJECTED/$seq.invalidmeta" 2>/dev/null || true
            record_result rejected_metadata "$nonce" 77 || true
            continue
        fi
        if ! validate_request "$claimed"; then
            mv "$claimed" "$REJECTED/$seq.invalid" 2>/dev/null || true
            record_result rejected_request "$nonce" 64 || true
            continue
        fi
        if [ "$REQUEST_NONCE" != "$nonce" ]; then
            mv "$claimed" "$REJECTED/$seq.nonce" 2>/dev/null || true
            record_result rejected_nonce "$nonce" 77 || true
            continue
        fi

        if ! : > "$claimed.execute"; then
            mv "$claimed" "$REJECTED/$seq.execution_intent_failed" 2>/dev/null || true
            record_result rejected_execution_intent "$nonce" 74 || true
            continue
        fi
        case "$REQUEST_OP" in
            start)
                sh "$MODDIR/bin/control.sh" "$MODDIR" start "$REQUEST_BAND" "$REQUEST_WIDTH"
                rc=$?
                ;;
            stop)
                sh "$MODDIR/bin/control.sh" "$MODDIR" stop
                rc=$?
                ;;
            c02-24g)
                sh "$MODDIR/bin/control.sh" "$MODDIR" c02-24g
                rc=$?
                ;;
            *)
                rc=64
                ;;
        esac
        mv "$claimed" "$BRIDGE/processed.$seq.req" 2>/dev/null || true
        rm -f "$claimed.execute" 2>/dev/null || true
        record_result "$REQUEST_OP:$REQUEST_BAND:$REQUEST_WIDTH" "$REQUEST_NONCE" "$rc" || true
        return 0
    done
    return 1
}
run_loop() {
    card_tick=0
    while :; do
        if [ ! -d "$MODDIR" ] || [ -L "$MODDIR" ] ||
           [ -e "$MODDIR/disable" ] || [ -e "$MODDIR/remove" ]; then
            timeout 3 sh "$MODDIR/bin/status-card.sh" "$MODDIR" update >/dev/null 2>&1 || true
            exit 0
        fi
        if process_one; then :; fi
        # Reuse this worker, without another daemon or changing radio settings.
        if [ "$card_tick" -eq 0 ]; then
            sh "$MODDIR/bin/status-card.sh" "$MODDIR" poll >/dev/null 2>&1 || true
        fi
        card_tick=$(((card_tick+1)%30))
        sleep 1
    done
}

worker_lock() {
    [ ! -L "$BRIDGE/worker.lock" ] || return 77
    exec 8>"$BRIDGE/worker.lock" || return 74
    flock -n 8 8>&8 || return 75
}

case "$OP" in
    start|stop)
        prepare_private
        [ ! -L "$BRIDGE/lifecycle.lock" ] || exit 77
        exec 6>"$BRIDGE/lifecycle.lock" || exit 74
        flock -n 6 6>&6 || exit 75
        ;;
esac

case "$OP" in
    start)
        prepare_private
        if worker_alive; then
            echo "worker=already_running pid=$(cat "$PID_FILE")"
            exit 0
        fi
        nohup setsid sh "$0" "$MODDIR" run >/dev/null 2>&1 6>&- < /dev/null &
        launched_pid=$!
        i=0
        while [ "$i" -lt 5 ]; do
            if worker_alive; then
                echo "worker=started pid=$(cat "$PID_FILE")"
                exit 0
            fi
            kill -0 "$launched_pid" 2>/dev/null || exit 70
            sleep 1
            i=$((i + 1))
        done
        exit 70
        ;;
    stop)
        if worker_alive; then
            kill "$(cat "$PID_FILE")" 2>/dev/null || true
        fi
        rm -f "$PID_FILE" "$START_FILE" "$BOOT_FILE"
        echo worker=stopped
        ;;
    status)
        if worker_alive; then
            echo "worker=alive pid=$(cat "$PID_FILE")"
        else
            echo worker=not_running
        fi
        [ -f "$RESULT" ] && sed -n '1,5p' "$RESULT"
        ;;
    run)
        prepare_private
        worker_lock || exit $?
        boot=$(boot_id) || exit 70
        printf '%s\n' "$$" > "$PID_FILE" || exit 70
        awk '{print $22}' "/proc/$$/stat" > "$START_FILE" || exit 70
        printf '%s\n' "$boot" > "$BOOT_FILE" || exit 70
        chmod 0600 "$PID_FILE" "$START_FILE" "$BOOT_FILE" || exit 74
        recover_claimed
        run_loop
        ;;
    once)
        prepare_private
        worker_lock || exit $?
        recover_claimed
        process_one || true
        ;;
esac
exit 0
