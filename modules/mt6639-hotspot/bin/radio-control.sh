#!/system/bin/sh
# One controller for both MT6639 radio layers: the 6GHz registration owned by
# mt6639-6g and the native 6GHz hotspot owned by this module.
#
# It never changes the radio itself. Every change goes through the two
# modules' own serialized entry points and their checks stay final. This file
# only orders them, refuses early when a start is already known to fail, and
# returns 6GHz to stock when it was the one that enabled it.
set -u
umask 077

HOTSPOT=${1:-/data/adb/modules/mt6639-hotspot}
OP=${2:-status}
ARG=${3:-}
SIX=/data/adb/modules/mt6639-6g
HOTSPOT_WORK=/data/adb/mt6639-hotspot
RADIO_WORK=/data/adb/mt6639-radio
RADIO_RECORD=$RADIO_WORK/session
WIDTH_FILE=$RADIO_WORK/width
RADIO_LOCK=$RADIO_WORK/control.lock
RADIO_LOG=$RADIO_WORK/control.log
SNAPSHOT=/data/misc/mt6639-hotspot/status

usage() {
    echo 'usage: radio-control.sh MODDIR status [full]|start [20|40|80|160|320]|stop|toggle|six-on|six-off|six-refresh|set-width WIDTH|logs' >&2
    exit 64
}
case "$HOTSPOT" in /data/adb/modules/mt6639-hotspot) ;; *) exit 64 ;; esac
[ "$#" -le 3 ] || usage
case "$OP" in
    status) case "$ARG" in ''|full) ;; *) usage ;; esac ;;
    start) case "$ARG" in ''|20|40|80|160|320) ;; *) usage ;; esac ;;
    set-width) case "$ARG" in 20|40|80|160|320) ;; *) usage ;; esac ;;
    stop|toggle|six-on|six-off|six-refresh|logs) [ -z "$ARG" ] || usage ;;
    *) usage ;;
esac
[ "$(id -u)" = 0 ] && [ "$(id -Z)" = u:r:ksu:s0 ] || exit 77
[ -d "$HOTSPOT" ] && [ ! -L "$HOTSPOT" ] || exit 66
# Callers started by KernelSU (action.sh) carry only PATH; the Android tools
# used below need the runtime environment. Same guarded source as control.sh.
if [ -f "$HOTSPOT/bin/android-env.sh" ] && [ ! -L "$HOTSPOT/bin/android-env.sh" ]; then
    . "$HOTSPOT/bin/android-env.sh"
fi

# Validate before any chmod, log, lock or record access; never follow a link.
work_parent=${RADIO_WORK%/*}
[ -d "$work_parent" ] && [ ! -L "$work_parent" ] &&
    [ "$(stat -c %u "$work_parent")" = 0 ] || exit 77
[ ! -L "$RADIO_WORK" ] || exit 77
if [ ! -e "$RADIO_WORK" ]; then mkdir -m 0700 "$RADIO_WORK" || exit 74; fi
[ -d "$RADIO_WORK" ] && [ "$(stat -c %u "$RADIO_WORK")" = 0 ] || exit 77
chmod 0700 "$RADIO_WORK" || exit 74
[ "$(stat -c %a "$RADIO_WORK")" = 700 ] || exit 77

boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) || exit 70
printf '%s\n' "$boot" |
    grep -Eq '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' || exit 70

FAIL_STEP=none
FAIL_REASON=none
FAIL_DETAIL=none
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$RADIO_LOG" 2>/dev/null; }
phase() { printf 'phase=%s\n' "$1"; log "phase=$1"; }
# fail STEP REASON RC [DETAIL]: record why, say it once, hand back RC.
fail() {
    FAIL_STEP=$1
    FAIL_REASON=$2
    FAIL_DETAIL=$(printf '%s' "${4:-none}" | tr ' ' ',' | tr -cd 'A-Za-z0-9_=,.-')
    [ -n "$FAIL_DETAIL" ] || FAIL_DETAIL=none
    printf 'REJECT %s\n' "$2" >&2
    return "$3"
}
last_reject() { sed -n 's/.*REJECT \([a-z0-9_][a-z0-9_]*\).*/\1/p' | tail -1; }
last_reject_reason() {
    sed -n 's/.*REJECT [a-z0-9_][a-z0-9_]* reason=\([a-z0-9_][a-z0-9_]*\).*/\1/p' | tail -1
}

# The lock serializes this controller only. Descriptor 8 is closed for every
# child: the 6GHz guardian and the hotspot runner outlive this script and keep
# whatever they inherit, which would hold the lock until they exit.
acquire_lock() {
    [ ! -L "$RADIO_LOCK" ] || return 77
    exec 8>"$RADIO_LOCK" || return 74
    lock_tries=$(( $1 * 5 ))
    lock_n=0
    while ! flock -n 8 8>&8; do
        if [ "$lock_n" -ge "$lock_tries" ]; then
            exec 8>&-
            return 75
        fi
        sleep 0.2
        lock_n=$((lock_n + 1))
    done
    return 0
}
lock_is_busy() {
    [ ! -L "$RADIO_LOCK" ] || return 0
    if ( exec 8>"$RADIO_LOCK" && flock -n 8 8>&8 ) 2>/dev/null; then return 1; fi
    return 0
}

module_state() {
    if [ ! -d "$1" ] || [ -L "$1" ] || [ ! -f "$1/bin/control.sh" ]; then
        echo missing
    elif [ -e "$1/remove" ]; then
        echo removing
    elif [ -e "$1/disable" ]; then
        echo disabled
    else
        echo present
    fi
}
module_version() {
    [ -f "$1/module.prop" ] && [ ! -L "$1/module.prop" ] || { echo unknown; return; }
    v=$(sed -n 's/^version=//p' "$1/module.prop" | head -1 | tr -cd 'A-Za-z0-9._-')
    echo "${v:-unknown}"
}
# Values come from the module's own shell configuration; read them in a
# subshell so they cannot replace this script's variables.
hotspot_config() {
    ( . "$HOTSPOT/config.conf" >/dev/null 2>&1; eval "printf '%s' \"\${$1:-}\"" ) 2>/dev/null
}
pref_width() {
    w=
    if [ -f "$WIDTH_FILE" ] && [ ! -L "$WIDTH_FILE" ] &&
        [ "$(stat -c %u "$WIDTH_FILE")" = 0 ]; then
        w=$(head -c 8 "$WIDTH_FILE" | head -1)
    fi
    case "$w" in 20|40|80|160|320) echo "$w"; return ;; esac
    w=$(hotspot_config WIDTH)
    case "$w" in 20|40|80|160|320) echo "$w" ;; *) echo 20 ;; esac
}
key_ok() {
    k=$HOTSPOT_WORK/private/ap.key
    [ -d "$HOTSPOT_WORK/private" ] && [ ! -L "$HOTSPOT_WORK/private" ] &&
        [ -f "$k" ] && [ ! -L "$k" ] &&
        [ "$(stat -c %u "$k")" = 0 ] && [ "$(stat -c %a "$k")" = 600 ]
}

# ---- 6GHz module -----------------------------------------------------------
six_field() { printf '%s\n' "$six_out" | sed -n "s/^$1=//p" | head -1; }
six_probe() {
    six_state=unknown six_tx=unknown six_tx_path= six_guardian=unknown
    six_profile=unknown six_compat_error=unknown six_boot_default=unknown six_ready=0
    six_out=$(timeout 20 sh "$SIX/bin/control.sh" "$SIX" status 8>&- 2>&1)
    six_rc=$?
    v=$(six_field state | tr -cd 'a-z_')
    [ -z "$v" ] || six_state=$v
    v=$(six_field active_tx)
    case "$v" in
        none) six_tx=none ;;
        /data/adb/mt6639-6g/transactions/t-*)
            case "${v#/data/adb/mt6639-6g/transactions/t-}" in
                ''|*[!a-zA-Z0-9-]*) six_tx=invalid ;;
                *) six_tx=present; six_tx_path=$v ;;
            esac ;;
        '') ;;
        *) six_tx=invalid ;;
    esac
    case "$(six_field guardian)" in
        alive) six_guardian=alive ;;
        not_running) six_guardian=not_running ;;
        '') [ "$six_tx" != none ] || six_guardian=none ;;
    esac
    v=$(six_field compatibility_profile | tr -cd 'A-Za-z0-9._-')
    [ -z "$v" ] || six_profile=$v
    v=$(six_field compatibility_error | tr -cd 'a-z0-9_')
    [ -z "$v" ] || six_compat_error=$v
    case "$(six_field enabled_config)" in 0) six_boot_default=0 ;; 1) six_boot_default=1 ;; esac
    if [ "$six_rc" = 0 ] && [ "$six_state" = active ] &&
        [ "$six_guardian" = alive ] && [ "$six_tx" = present ]; then
        six_ready=1
    fi
    [ "$six_rc" = 0 ]
}
run_six() {
    sub_out=$(timeout "$1" sh "$SIX/bin/control.sh" "$SIX" "$2" 8>&- 2>&1)
}

# ---- hotspot module --------------------------------------------------------
hot_field() { printf '%s\n' "$hot_out" | sed -n "s/^$1=//p" | head -1; }
# Same protocol as status-card.sh poll: the read-only controller check is
# serialized with hotspot actions and skipped while one runs, because a check
# taken in the middle of a start would publish "unresolved".
hotspot_probe() {
    hot_out= hot_rc=0 hot_state=unknown hot_freq=none hot_channel=none
    if [ -d "$HOTSPOT_WORK" ] && [ ! -L "$HOTSPOT_WORK" ]; then
        [ ! -L "$HOTSPOT_WORK/action.lock" ] || { hot_rc=77; return 77; }
        exec 7>"$HOTSPOT_WORK/action.lock" || { hot_rc=74; return 74; }
        if ! flock -n 7 7>&7; then
            exec 7>&-
            hot_rc=75
            return 75
        fi
    fi
    hot_out=$(timeout 30 sh "$HOTSPOT/bin/control.sh" "$HOTSPOT" status 7>&- 8>&- 2>&1)
    hot_rc=$?
    exec 7>&-
    case "$(hot_field state)" in
        idle) hot_state=idle ;; starting) hot_state=starting ;; active) hot_state=active ;;
        stopping) hot_state=stopping ;; unresolved) hot_state=unresolved ;;
    esac
    v=$(hot_field freq)
    case "$v" in ''|*[!0-9]*) ;; *) hot_freq=$v ;; esac
    v=$(hot_field channel)
    case "$v" in ''|*[!0-9]*) ;; *) hot_channel=$v ;; esac
    return "$hot_rc"
}
# The public snapshot is the only place the controller publishes band and
# width. Extract fixed keys and accept fixed values; never evaluate it.
snap_field() { printf '%s\n' "$snap_data" | sed -n "s/^$1=//p" | head -1; }
snapshot_read() {
    snap_state=unknown snap_band=none snap_width=none snap_age=unknown
    [ -f "$SNAPSHOT" ] && [ ! -L "$SNAPSHOT" ] && [ ! -L "${SNAPSHOT%/*}" ] &&
        [ "$(stat -c %u "$SNAPSHOT")" = 0 ] &&
        [ "$(stat -c %s "$SNAPSHOT")" -le 4096 ] || return 1
    snap_mtime=$(stat -c %Y "$SNAPSHOT") || return 1
    snap_data=$(cat "$SNAPSHOT") || return 1
    [ "$(snap_field schema)" = mt6639-hotspot-status-v3 ] || return 1
    [ "$(snap_field boot)" = "$boot" ] || return 1
    # All three values are accepted together or not at all.
    s_state=$(snap_field state)
    s_band=$(snap_field band)
    s_width=$(snap_field width)
    case "$s_state" in idle|starting|active|stopping|unresolved|disabled) ;; *) return 1 ;; esac
    case "$s_band" in none|2g|5g|6g) ;; *) return 1 ;; esac
    case "$s_width" in none|20|40|80|160|320) ;; *) return 1 ;; esac
    snap_state=$s_state
    snap_band=$s_band
    snap_width=$s_width
    now=$(date +%s)
    case "$snap_mtime:$now" in
        *[!0-9:]*) ;;
        *) [ "$now" -lt "$snap_mtime" ] || snap_age=$((now - snap_mtime)) ;;
    esac
    return 0
}
run_hotspot() {
    hs_timeout=$1
    shift
    sub_out=$(timeout "$hs_timeout" sh "$HOTSPOT/bin/control.sh" "$HOTSPOT" "$@" 8>&- 2>&1)
}

# Reviewed device / SDK / kernel / driver tuple, as the hotspot start requires.
identity_probe() {
    identity_reason=none
    v=$(sh "$HOTSPOT/bin/hotspot-identity.sh" "$HOTSPOT/bin" 8>&- 2>&1) && return 0
    identity_reason=$(printf '%s\n' "$v" | last_reject)
    [ -n "$identity_reason" ] || identity_reason=identity_check_failed
    return 1
}

# ---- station and upstream ---------------------------------------------------
# Uses the hotspot module's own resolver on one captured status, so this view
# and the later start agree. Only the mode and a frequency leave this function.
wifi_probe() {
    wifi=unknown sta=unknown sta_freq=none upstream=unknown upstream_reason=none
    upstream_ok=0 cell_data=na
    wifi_out=$(timeout 5 cmd wifi status 8>&- 2>/dev/null) || return 1
    if printf '%s\n' "$wifi_out" | grep -Fxq 'Wifi is enabled'; then wifi=1; else wifi=0; fi
    if printf '%s\n' "$wifi_out" | grep -Fq 'Wifi is connected to "'; then
        sta=connected
        v=$(printf '%s\n' "$wifi_out" |
            sed -n 's/.*Frequency: \([0-9][0-9]*\)MHz.*/\1/p' | head -1)
        case "$v" in ''|*[!0-9]*) ;; *) sta_freq=$v ;; esac
    else
        sta=disconnected
    fi
    request=$(hotspot_config MT6639_HOTSPOT_UPSTREAM)
    case "$request" in auto|wifi|wifi-any|cell) ;; *) request=auto ;; esac
    v=$(printf '%s\n' "$wifi_out" |
        sh "$HOTSPOT/bin/hotspot-upstream.sh" "$request" 6g /proc/self/fd/0 8>&- 2>&1)
    if [ "$?" = 0 ]; then
        case "$v" in
            cell)
                upstream=cell
                if timeout 5 ip -4 addr show 8>&- 2>/dev/null |
                    grep -Eq 'inet [0-9.]+/.* (rmnet|ccmni|wwan)[0-9]*'; then
                    cell_data=1
                    upstream_ok=1
                else
                    cell_data=0
                    upstream_reason=cellular_data_unavailable
                fi ;;
            wifi|wifi-any)
                upstream=$v
                # A 6GHz AP next to a 2.4/5GHz station is moved to the
                # station's channel by this driver; the runner refuses it.
                if [ "$sta_freq" != none ] && [ "$sta_freq" -ge 5950 ] &&
                    [ "$sta_freq" -le 7125 ]; then
                    upstream_ok=1
                else
                    upstream_reason=sta_band_incompatible_with_6g
                fi ;;
            *) upstream=rejected; upstream_reason=upstream_preflight_failed ;;
        esac
    else
        upstream=rejected
        upstream_reason=$(printf '%s\n' "$v" | last_reject)
        [ -n "$upstream_reason" ] || upstream_reason=upstream_preflight_failed
    fi
    return 0
}
# Refuse a start that is already known to fail, before any radio change.
upstream_preflight() {
    wifi_probe || { fail preflight sta_status_unavailable 69; return $?; }
    [ "$wifi" = 1 ] || { fail preflight wifi_disabled 69; return $?; }
    # The modem attaches a moment after the station drops; the runner allows
    # the same bounded wait.
    pf_n=0
    while [ "$upstream" = cell ] && [ "$upstream_ok" != 1 ] && [ "$pf_n" -lt 10 ]; do
        sleep 1
        pf_n=$((pf_n + 1))
        wifi_probe || { fail preflight sta_status_unavailable 69; return $?; }
    done
    [ "$upstream_ok" = 1 ] || {
        fail preflight "$upstream_reason" 69 "upstream=$upstream sta_freq=$sta_freq"
        return $?
    }
}
# Enabling 6GHz restarts Wi-Fi. Wait until three samples two seconds apart
# agree, so the hotspot preflight does not judge a station that is still
# reconnecting. The strict preflight afterwards makes the decision.
sta_settle() {
    st_prev= st_same=0 st_n=0
    while [ "$st_n" -lt 10 ]; do
        if wifi_probe && [ "$wifi" = 1 ] && [ "$upstream" != rejected ]; then
            st_cur="$sta:$sta_freq:$upstream"
        else
            st_cur=unsettled
        fi
        if [ "$st_cur" != unsettled ] && [ "$st_cur" = "$st_prev" ]; then
            st_same=$((st_same + 1))
            [ "$st_same" -lt 2 ] || return 0
        else
            st_same=0
        fi
        st_prev=$st_cur
        sleep 2
        st_n=$((st_n + 1))
    done
    return 0
}

# ---- ownership record -------------------------------------------------------
# owns_6g=1 means this controller enabled the recorded transaction and still
# has to return it. The record is trusted only for the same boot and the same
# transaction path; anything else is never used to disable 6GHz.
record_parse() {
    rec_owns=0 rec_tx=none rec_width=
    [ -f "$RADIO_RECORD" ] && [ ! -L "$RADIO_RECORD" ] && [ "$(stat -c %u "$RADIO_RECORD")" = 0 ] &&
        [ "$(stat -c %s "$RADIO_RECORD")" -le 1024 ] || return 2
    rec_data=$(cat "$RADIO_RECORD") || return 2
    rec_get() { printf '%s\n' "$rec_data" | sed -n "s/^$1=//p" | head -1; }
    [ "$(rec_get schema)" = mt6639-radio-session-v1 ] || return 2
    printf '%s\n' "$(rec_get boot)" |
        grep -Eq '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' || return 2
    [ "$(rec_get boot)" = "$boot" ] || return 3
    case "$(rec_get owns_6g)" in 0|1) ;; *) return 2 ;; esac
    case "$(rec_get width)" in 20|40|80|160|320) ;; *) return 2 ;; esac
    v=$(rec_get tx)
    case "$v" in
        none) ;;
        /data/adb/mt6639-6g/transactions/t-*)
            case "${v#/data/adb/mt6639-6g/transactions/t-}" in
                ''|*[!a-zA-Z0-9-]*) return 2 ;;
            esac ;;
        *) return 2 ;;
    esac
    rec_owns=$(rec_get owns_6g)
    rec_tx=$v
    rec_width=$(rec_get width)
    return 0
}
# 0 usable, 1 none. Call with the lock held: an earlier boot's record is
# dropped, a malformed one is kept aside as evidence and never acted on.
record_load() {
    rec_owns=0 rec_tx=none rec_width=
    [ -e "$RADIO_RECORD" ] || [ -L "$RADIO_RECORD" ] || return 1
    record_parse
    case "$?" in
        0) return 0 ;;
        3) rm -f "$RADIO_RECORD"; log 'session record from an earlier boot dropped' ;;
        *)
            mv -f "$RADIO_RECORD" "$RADIO_WORK/session.invalid.$(date +%s)" 2>/dev/null ||
                rm -f "$RADIO_RECORD" 2>/dev/null
            log 'session record invalid; set aside, 6GHz ownership not assumed' ;;
    esac
    rec_owns=0 rec_tx=none rec_width=
    return 1
}
record_save() {
    rec_tmp=$RADIO_WORK/.session.$$
    printf 'schema=mt6639-radio-session-v1\nboot=%s\nowns_6g=%s\ntx=%s\nwidth=%s\n' \
        "$boot" "$1" "$2" "$3" > "$rec_tmp" && chmod 0600 "$rec_tmp" &&
        mv -f "$rec_tmp" "$RADIO_RECORD"
}

# ---- operations --------------------------------------------------------------
six_rollback() {
    phase six_rollback
    run_six 200 disable
    rb_rc=$?
    [ -z "$sub_out" ] || printf '%s\n' "$sub_out"
    if [ "$rb_rc" = 0 ]; then
        rm -f "$RADIO_RECORD"
        echo 'rollback=restored'
    else
        # The record stays: a later stop can finish returning 6GHz.
        log "rollback: 6GHz restore failed rc=$rb_rc; record kept"
        echo "rollback=failed rc=$rb_rc"
    fi
}

op_start() {
    width=${ARG:-$(pref_width)}
    phase preflight
    [ "$(module_state "$SIX")" = present ] || {
        fail preflight "sixg_module_$(module_state "$SIX")" 66; return $?; }
    [ "$(module_state "$HOTSPOT")" = present ] || {
        fail preflight "hotspot_module_$(module_state "$HOTSPOT")" 73; return $?; }
    [ "$(getenforce 2>/dev/null)" = Enforcing ] || {
        fail preflight enforcing_required 77; return $?; }
    android_env_ready 2>/dev/null || { fail preflight android_env_unavailable 69; return $?; }
    key_ok || { fail preflight ap_key_missing 66; return $?; }
    sh "$HOTSPOT/bin/verify-module.sh" "$HOTSPOT" 8>&- >/dev/null 2>&1 || {
        fail preflight module_asset_hash_mismatch 69; return $?; }
    identity_probe || { fail preflight "$identity_reason" 69; return $?; }
    [ ! -e /sys/class/net/mtap0 ] || { fail preflight mtap0_exists 73; return $?; }
    timeout 5 dumpsys tethering --short 8>&- 2>/dev/null |
        grep -Fxq '    Upstream wanted: false' || {
        fail preflight tethering_not_idle 73; return $?; }
    hotspot_probe
    case "$?" in
        0) ;;
        75) fail preflight hotspot_busy 75; return $? ;;
        *) fail preflight hotspot_status_unavailable 69 "rc=$hot_rc"; return $? ;;
    esac
    snapshot_read || :
    case "$hot_state" in
        idle) ;;
        active)
            if [ "$snap_band" = 6g ] && [ "$snap_width" = "$width" ]; then
                echo "combined=already_active width=$width"
                return 0
            fi
            fail preflight hotspot_active_other_profile 73 "band=$snap_band width=$snap_width"
            return $? ;;
        *) fail preflight hotspot_not_idle 73 "state=$hot_state"; return $? ;;
    esac
    six_probe || [ "$six_tx" = invalid ] || {
        fail preflight sixg_status_unavailable 69 "rc=$six_rc"; return $?; }
    enabled_now=0
    if [ "$six_ready" = 1 ]; then
        :
    elif [ "$six_tx" = none ]; then
        enabled_now=1
    else
        fail preflight sixg_needs_recovery 73 "state=$six_state guardian=$six_guardian tx=$six_tx"
        return $?
    fi
    upstream_preflight || return $?

    owns=0
    if [ "$enabled_now" = 1 ]; then
        phase six_enable
        run_six 200 enable
        rc=$?
        [ -z "$sub_out" ] || printf '%s\n' "$sub_out"
        if [ "$rc" != 0 ]; then
            # Nothing of ours to undo: the 6GHz module keeps its own authority.
            reason=$(printf '%s\n' "$sub_out" | last_reject)
            fail six_enable "${reason:-sixg_enable_failed}" "$rc"
            return $?
        fi
        six_probe || :
        if [ "$six_ready" != 1 ]; then
            six_rollback
            fail six_enable sixg_not_active_after_enable 69 "state=$six_state guardian=$six_guardian"
            return $?
        fi
        owns=1
        # Ownership is durable before the hotspot is touched.
        record_save 1 "$six_tx_path" "$width" || {
            six_rollback
            fail six_enable session_record_unwritable 74
            return $?
        }
        phase sta_settle
        sta_settle
        upstream_preflight
        rc=$?
        if [ "$rc" != 0 ]; then
            six_rollback
            return "$rc"
        fi
    elif record_load && [ "$rec_owns" = 1 ] && [ "$rec_tx" = "$six_tx_path" ]; then
        # An earlier one-tap start enabled this very transaction and it was
        # never handed back (the hotspot was stopped some other way).
        owns=1
    fi

    phase hotspot_start
    run_hotspot 480 start 6g "$width"
    rc=$?
    [ -z "$sub_out" ] || printf '%s\n' "$sub_out"
    if [ "$rc" != 0 ]; then
        reason=$(printf '%s\n' "$sub_out" | last_reject)
        detail=$(printf '%s\n' "$sub_out" | last_reject_reason)
        [ "$enabled_now" = 0 ] || six_rollback
        fail hotspot_start "${reason:-hotspot_start_failed}" "$rc" "${detail:-none}"
        return $?
    fi
    phase verify
    hotspot_probe || :
    snapshot_read || :
    if [ "$hot_state" != active ] || [ "$snap_band" != 6g ] || [ "$snap_width" != "$width" ]; then
        run_hotspot 360 stop
        [ -z "$sub_out" ] || printf '%s\n' "$sub_out"
        [ "$enabled_now" = 0 ] || six_rollback
        fail verify hotspot_not_active_after_start 69 \
            "state=$hot_state band=$snap_band width=$snap_width"
        return $?
    fi
    # The hotspot is up; a record that cannot be refreshed must not take it down.
    record_save "$owns" "${six_tx_path:-none}" "$width" ||
        log 'start: session record not refreshed'
    echo "combined=active width=$width owns_6g=$owns freq=$hot_freq channel=$hot_channel"
    return 0
}

op_stop() {
    phase hotspot_stop
    hotspot_probe
    [ "$?" != 75 ] || { fail hotspot_stop hotspot_busy 75; return $?; }
    if [ "$hot_rc" != 0 ] || [ "$hot_state" != idle ]; then
        run_hotspot 360 stop
        rc=$?
        [ -z "$sub_out" ] || printf '%s\n' "$sub_out"
        if [ "$rc" != 0 ]; then
            reason=$(printf '%s\n' "$sub_out" | last_reject)
            fail hotspot_stop "${reason:-hotspot_stop_failed}" "$rc"
            return $?
        fi
        hotspot_probe || :
        if [ "$hot_rc" != 0 ] || [ "$hot_state" != idle ]; then
            fail hotspot_stop hotspot_not_confirmed_idle 73 "state=$hot_state rc=$hot_rc"
            return $?
        fi
    fi
    if record_load; then
        if [ "$rec_owns" = 1 ] && [ "$(module_state "$SIX")" != missing ]; then
            six_probe || :
            if [ "$six_tx" = unknown ]; then
                # Unreadable, not absent: keep the record so a retry can finish.
                fail six_restore sixg_status_unavailable 69 "rc=$six_rc"
                return $?
            elif [ "$six_tx" = present ] && [ "$six_tx_path" = "$rec_tx" ]; then
                phase six_restore
                run_six 200 disable
                rc=$?
                [ -z "$sub_out" ] || printf '%s\n' "$sub_out"
                if [ "$rc" != 0 ]; then
                    reason=$(printf '%s\n' "$sub_out" | last_reject)
                    fail six_restore "${reason:-sixg_restore_failed}" "$rc"
                    return $?
                fi
                echo 'six=restored'
            else
                log 'stop: the recorded 6GHz transaction is gone or replaced; left as is'
            fi
        fi
        rm -f "$RADIO_RECORD" || { fail record session_record_unremovable 74; return $?; }
    fi
    echo 'combined=idle'
    return 0
}

op_six_on() {
    phase six_enable
    [ "$(module_state "$SIX")" = present ] || {
        fail six_enable "sixg_module_$(module_state "$SIX")" 66; return $?; }
    six_probe || [ "$six_tx" = invalid ] || {
        fail six_enable sixg_status_unavailable 69 "rc=$six_rc"; return $?; }
    if [ "$six_ready" = 1 ]; then
        echo 'six=already_active'
        return 0
    fi
    [ "$six_tx" = none ] || {
        fail six_enable sixg_needs_recovery 73 "state=$six_state guardian=$six_guardian tx=$six_tx"
        return $?
    }
    run_six 200 enable
    rc=$?
    [ -z "$sub_out" ] || printf '%s\n' "$sub_out"
    if [ "$rc" != 0 ]; then
        reason=$(printf '%s\n' "$sub_out" | last_reject)
        fail six_enable "${reason:-sixg_enable_failed}" "$rc"
        return $?
    fi
    six_probe || :
    [ "$six_ready" = 1 ] || {
        fail six_enable sixg_not_active_after_enable 69 "state=$six_state guardian=$six_guardian"
        return $?
    }
    echo 'six=active'
    return 0
}

# Restoring or re-registering 6GHz restarts Wi-Fi and would take a running
# hotspot down under its guardian. Require the hotspot to be idle first.
require_hotspot_idle() {
    hotspot_probe
    case "$?" in
        0) ;;
        75) fail "$1" hotspot_busy 75; return $? ;;
        *) fail "$1" hotspot_status_unavailable 69 "rc=$hot_rc"; return $? ;;
    esac
    [ "$hot_state" = idle ] || { fail "$1" hotspot_active 73 "state=$hot_state"; return $?; }
}

op_six_off() {
    phase six_restore
    [ "$(module_state "$SIX")" != missing ] || { fail six_restore sixg_module_missing 66; return $?; }
    require_hotspot_idle six_restore || return $?
    run_six 200 disable
    rc=$?
    [ -z "$sub_out" ] || printf '%s\n' "$sub_out"
    if [ "$rc" != 0 ]; then
        reason=$(printf '%s\n' "$sub_out" | last_reject)
        fail six_restore "${reason:-sixg_restore_failed}" "$rc"
        return $?
    fi
    # Nothing is left to hand back.
    rm -f "$RADIO_RECORD" 2>/dev/null
    echo 'six=restored'
    return 0
}

op_six_refresh() {
    phase six_refresh
    [ "$(module_state "$SIX")" = present ] || {
        fail six_refresh "sixg_module_$(module_state "$SIX")" 66; return $?; }
    require_hotspot_idle six_refresh || return $?
    run_six 120 refresh
    rc=$?
    [ -z "$sub_out" ] || printf '%s\n' "$sub_out"
    if [ "$rc" != 0 ]; then
        reason=$(printf '%s\n' "$sub_out" | sed -n 's/.*refresh-6g: FAIL \([a-z0-9_]*\).*/\1/p' | tail -1)
        [ -n "$reason" ] || reason=$(printf '%s\n' "$sub_out" | last_reject)
        fail six_refresh "${reason:-sixg_refresh_failed}" "$rc"
        return $?
    fi
    echo 'six=refreshed'
    return 0
}

op_set_width() {
    w_tmp=$RADIO_WORK/.width.$$
    printf '%s\n' "$ARG" > "$w_tmp" && chmod 0600 "$w_tmp" && mv -f "$w_tmp" "$WIDTH_FILE" || {
        rm -f "$w_tmp"
        fail set_width width_unwritable 74
        return $?
    }
    echo "pref_width=$ARG"
}

# The module "action" button: one press for both layers.
op_toggle() {
    hotspot_probe
    case "$?" in
        75) fail toggle hotspot_busy 75; return $? ;;
    esac
    if [ "$hot_rc" = 0 ] && [ "$hot_state" = idle ]; then
        echo "一键开启：6GHz + 热点（带宽 $(pref_width)MHz）"
        op_start
    else
        echo '一键关闭：停止热点，并归还由一键开启启用的 6GHz'
        op_stop
    fi
}

card_text() { tr -d '\r' | head -1 | head -c 2000; }

op_status() {
    mode=light
    busy=0
    if [ "$ARG" = full ]; then
        # A checked status is serialized with this controller's operations.
        if acquire_lock 0; then mode=full; else busy=1; fi
    elif lock_is_busy; then
        busy=1
    fi
    echo 'schema=mt6639-radio-status-v1'
    echo "mode=$mode"
    echo "boot=$boot"
    echo "busy=$busy"

    six_module=$(module_state "$SIX")
    echo "six_module=$six_module"
    echo "six_version=$(module_version "$SIX")"
    if [ "$six_module" != missing ]; then
        six_probe || :
        echo "six_status_rc=$six_rc"
        echo "six_state=$six_state"
        echo "six_tx=$six_tx"
        echo "six_guardian=$six_guardian"
        echo "six_profile=$six_profile"
        echo "six_compat_error=$six_compat_error"
        echo "six_boot_default=$six_boot_default"
        echo "six_ready=$six_ready"
        card=
        if [ "$mode" = full ] && [ -f "$SIX/bin/status-card.sh" ]; then
            card=$(timeout 10 sh "$SIX/bin/status-card.sh" "$SIX" show 8>&- 2>/dev/null | card_text)
        fi
        if [ -z "$card" ] && [ -f "$SIX/module.prop" ] && [ ! -L "$SIX/module.prop" ]; then
            card=$(sed -n 's/^description=//p' "$SIX/module.prop" | card_text)
        fi
        echo "six_card=$card"
    fi

    echo "hotspot_module=$(module_state "$HOTSPOT")"
    echo "hotspot_version=$(module_version "$HOTSPOT")"
    hot_checked=0
    if [ "$mode" = full ]; then
        hotspot_probe
        [ "$?" = 75 ] || hot_checked=1
    fi
    snap_ok=0
    snapshot_read && snap_ok=1
    if [ "$hot_checked" = 1 ]; then
        echo "hotspot_status_rc=$hot_rc"
        echo "hotspot_state=$hot_state"
        echo "hotspot_freq=$hot_freq"
        echo "hotspot_channel=$hot_channel"
    else
        echo "hotspot_state=$snap_state"
    fi
    echo "hotspot_checked=$hot_checked"
    echo "hotspot_snapshot=$snap_ok"
    echo "hotspot_band=$snap_band"
    echo "hotspot_width=$snap_width"
    echo "hotspot_age=$snap_age"

    if [ "$(getenforce 2>/dev/null)" = Enforcing ]; then echo enforcing=1; else echo enforcing=0; fi
    if key_ok; then echo ap_key=1; else echo ap_key=0; fi
    if [ "$mode" = full ]; then
        if sh "$HOTSPOT/bin/verify-module.sh" "$HOTSPOT" 8>&- >/dev/null 2>&1; then
            echo integrity=1
        else
            echo integrity=0
        fi
        if identity_probe; then echo identity=1; else echo identity=0; fi
        echo "identity_reason=$identity_reason"
    fi
    wifi_probe || :
    echo "wifi=$wifi"
    echo "sta=$sta"
    echo "sta_freq=$sta_freq"
    echo "upstream=$upstream"
    echo "upstream_ok=$upstream_ok"
    echo "upstream_reason=$upstream_reason"
    echo "cell_data=$cell_data"

    # Read only: cleanup of a stale record belongs to an operation under lock.
    owns=0
    if record_parse && [ "$rec_owns" = 1 ]; then owns=1; fi
    echo "session_owns_6g=$owns"
    echo "pref_width=$(pref_width)"
    echo 'end=1'
    [ "$mode" != full ] || exec 8>&-
    return 0
}

log_tail() {
    printf '=== %s ===\n' "$1"
    if [ -f "$2" ] && [ ! -L "$2" ]; then tail -n 60 "$2" 2>/dev/null; fi
}
op_logs() {
    log_tail radio "$RADIO_LOG"
    log_tail hotspot "$HOTSPOT_WORK/control.log"
    log_tail sixg /data/adb/mt6639-6g/apply.log
}

case "$OP" in
    status) op_status; exit $? ;;
    logs) op_logs; exit 0 ;;
    toggle)
        # The one-tap path is the 6GHz hotspot. Another configured band keeps
        # the module's original single-layer toggle.
        if [ "$(hotspot_config BAND)" != 6g ] && [ -n "$(hotspot_config BAND)" ]; then
            exec sh "$HOTSPOT/bin/control.sh" "$HOTSPOT" toggle
        fi ;;
esac

# A status check from the same console may still hold the lock for a moment.
acquire_lock 3 || {
    rc=$?
    echo 'REJECT radio_control_busy' >&2
    echo "result=failed step=lock reason=radio_control_busy detail=none rc=$rc"
    exit "$rc"
}
if [ -f "$RADIO_LOG" ] && [ ! -L "$RADIO_LOG" ] && [ "$(stat -c %s "$RADIO_LOG")" -gt 262144 ]; then
    mv -f "$RADIO_LOG" "$RADIO_LOG.1"
fi
log "op=$OP arg=${ARG:-none} begin"
case "$OP" in
    start) op_start ;;
    stop) op_stop ;;
    toggle) op_toggle ;;
    six-on) op_six_on ;;
    six-off) op_six_off ;;
    six-refresh) op_six_refresh ;;
    set-width) op_set_width ;;
esac
rc=$?
if [ "$rc" = 0 ]; then
    echo 'result=ok'
else
    echo "result=failed step=$FAIL_STEP reason=$FAIL_REASON detail=$FAIL_DETAIL rc=$rc"
fi
if [ "$OP" = toggle ]; then
    if [ "$rc" = 0 ]; then
        echo '完成。'
    else
        echo "未完成：$FAIL_REASON（步骤 $FAIL_STEP，rc=$rc）。可在模块 WebUI 控制台查看说明。"
    fi
fi
log "op=$OP end rc=$rc step=$FAIL_STEP reason=$FAIL_REASON detail=$FAIL_DETAIL"
exit "$rc"
