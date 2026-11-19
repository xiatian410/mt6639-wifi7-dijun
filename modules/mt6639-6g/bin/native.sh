#!/system/bin/sh
# Production wrapper around the native fixed-target transaction executor.
# Internal apply/restore require control.sh serialization; public mutation
# entrypoints are control.sh, apply.sh, restore.sh and the KSU lifecycle scripts.
set -u
MODDIR=${1:-${MODDIR:-/data/adb/modules/mt6639-6g}}
. "$MODDIR/bin/owner.sh"
case "${2:-}" in
    apply|restore) require_owner_mutation || exit 3 ;;
esac
if [ "$MODULE_EMBEDDED" = 1 ] && [ "${2:-}" = apply ]; then
    require_owner_enabled || exit 3
fi
. "$MODDIR/bin/lib.sh"

TXN_ROOT=$WORK/transactions

die() { code=$1; shift; log "native: $*"; exit "$code"; }

need_native() {
    [ -f "$NATIVE" ] || die 3 "REJECT native_missing"
    # KernelSU extraction normalizes packaged files to 0644. Repair only this
    # module-owned executable; an unreadable or wrong image still fails.
    if [ ! -x "$NATIVE" ]; then
        # Even observational entrypoints must guard a permission repair in the
        # unified install; a stale install may be inspected, not mutated.
        require_owner_mutation || die 3 "REJECT owner_mutation_blocked"
        chmod 0755 "$NATIVE" || die 3 "REJECT native_not_executable"
    fi
}

active_tx() {
    [ ! -L "$ACTIVE_TX_FILE" ] || return 2
    [ -e "$ACTIVE_TX_FILE" ] || return 1
    [ -f "$ACTIVE_TX_FILE" ] && [ -r "$ACTIVE_TX_FILE" ] || return 2
    [ -s "$ACTIVE_TX_FILE" ] || return 1
    tx=$(cat "$ACTIVE_TX_FILE" 2>/dev/null) || return 2
    suffix=${tx#"$TXN_ROOT"/t-}
    case "$tx" in
        "$TXN_ROOT"/t-*)
            case "$suffix" in ''|*[!a-zA-Z0-9-]*) return 2 ;; esac ;;
        *) return 2 ;;
    esac
    [ ! -L "$tx" ] && [ ! -L "$TXN_ROOT" ] || return 2
    printf '%s\n' "$tx"
}

guardian_alive() {
    [ ! -L "$ACTIVE_PID_FILE" ] && [ -f "$ACTIVE_PID_FILE" ] || return 1
    pid=$(cat "$ACTIVE_PID_FILE" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] && kill -0 "$pid" 2>/dev/null || return 1
    [ "$(readlink "/proc/$pid/exe" 2>/dev/null)" = "$NATIVE" ] || return 1
    # A PID from another transaction using the same binary is not ours.
    guardian_args=$(tr '\000' '\n' <"/proc/$pid/cmdline" 2>/dev/null) || return 1
    case "$(printf '%s\n' "$guardian_args" | sed -n '2p')" in
        run-wlan|run-wlan-persistent) ;;
        *) return 1 ;;
    esac
    [ "$(printf '%s\n' "$guardian_args" | sed -n '3p')" = "$1" ]
}

pid_authority_safe() {
    [ ! -L "$ACTIVE_PID_FILE" ] &&
        { [ ! -e "$ACTIVE_PID_FILE" ] || [ -f "$ACTIVE_PID_FILE" ]; }
}

valid_boot() {
    printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
}

# Called under control.sh's flock. Never recover an old boot's journal against
# this boot's kernel; retire only its wrapper authority after proving stock.
cmd_reconcile() {
    pid_authority_safe || { log 'REJECT active_pid_invalid'; return 3; }
    if tx=$(active_tx); then :; else
        rc=$?
        [ "$rc" = 1 ] && return 0
        log 'REJECT active_tx_invalid'; return 3
    fi
    [ -d "$tx" ] && [ ! -L "$tx/wrapper-boot" ] || {
        log 'REJECT transaction_or_boot_invalid'; return 3; }
    old_boot=$(cat "$tx/wrapper-boot" 2>/dev/null) || return 3
    current_boot=$(boot_id) || return 3
    if [ "$old_boot" = "$current_boot" ]; then
        if guardian_alive "$tx"; then
            log "native already active tx=$tx"
            return 10
        fi
        cmd_restore
        return $?
    fi
    valid_boot "$old_boot" && valid_boot "$current_boot" || {
        log 'REJECT invalid_cross_boot_record'; return 3; }
    guardian_alive "$tx" && { log 'REJECT cross_boot_live_guardian'; return 3; }
    require_identity && require_unmounted && require_unmounted "$INIT_MOUNTINFO_FILE" || return 3
    [ "$(file_sha "$INIT_CFG_PATH")" = "$STOCK_CFG_SHA" ] || {
        log 'REJECT init_cfg_not_stock'; return 3; }
    retired=$WORK/retired
    [ ! -L "$retired" ] || { log 'REJECT retired_symlink'; return 3; }
    mkdir -p "$retired" && chmod 0700 "$retired" || return 3
    archive=$(mktemp -d "$retired/r-${old_boot}-XXXXXX") || return 3
    cp "$ACTIVE_TX_FILE" "$archive/active_tx" &&
        cp "$tx/wrapper-boot" "$archive/wrapper-boot" || return 3
    if [ -e "$ACTIVE_PID_FILE" ]; then
        cp "$ACTIVE_PID_FILE" "$archive/active_pid" || return 3
    fi
    printf '%s\n' "$current_boot" >"$archive/retired-on-boot" || return 3
    sync
    cmp -s "$ACTIVE_TX_FILE" "$archive/active_tx" &&
        cmp -s "$tx/wrapper-boot" "$archive/wrapper-boot" || return 3
    clear_active || return 3
    echo retired_stock >"$STATE"
    log "native old-boot authority retired (not recovered) tx=$tx archive=$archive"
}

write_active() {
    printf '%s\n' "$1" >"$ACTIVE_TX_FILE" || return 1
    sync
}

clear_active() {
    : >"$ACTIVE_TX_FILE" || return 1
    : >"$ACTIVE_PID_FILE" || return 1
    sync
}

json_pid() {
    sed -n 's/.*"guardian_pid":\([0-9][0-9]*\).*/\1/p' | head -1
}

cmd_inspect() {
    need_native
    "$NATIVE" inspect
    "$NATIVE" inspect-wlan
}

cmd_status() {
    echo "boot=$(boot_id)"
    echo "compatibility_profile=$COMPAT_PROFILE"
    echo "compatibility_error=${COMPAT_ERROR:-none}"
    enabled=$(grep '^ENABLE_6G=' "$MODDIR/config.conf" 2>/dev/null | head -1 |
              sed 's/.*:-\([01]\).*/\1/; s/^ENABLE_6G=//')
    echo "enabled_config=${enabled:-unknown}"
    echo "state=$(cat "$STATE" 2>/dev/null || echo none)"
    if tx=$(active_tx); then
        echo "active_tx=$tx"
        echo "guardian_pid=$(cat "$ACTIVE_PID_FILE" 2>/dev/null)"
        if guardian_alive "$tx"; then echo "guardian=alive"; else echo "guardian=not_running"; fi
        tail -3 "$tx/guardian.log" 2>/dev/null || true
    else
        rc=$?
        [ "$rc" = 1 ] || { echo active_tx=invalid; return 3; }
        echo active_tx=none
    fi
}

cmd_apply() {
    need_native
    [ -f "$MODDIR/config.conf" ] && . "$MODDIR/config.conf"
    if [ "${ENABLE_6G:-0}" != 1 ]; then
        log "native apply skipped: ENABLE_6G=${ENABLE_6G:-0}"
        return 0
    fi
    case "${RUN_MODE:-persistent}" in
        persistent|bounded) ;;
        *) log 'REJECT invalid_run_mode'; return 3 ;;
    esac
    [ ! -L "$TXN_ROOT" ] && { [ ! -e "$TXN_ROOT" ] || [ -d "$TXN_ROOT" ]; } || {
        log 'REJECT transaction_root_invalid'; return 3; }
    cmd_reconcile
    rc=$?
    [ "$rc" != 10 ] || return 0
    [ "$rc" = 0 ] || return "$rc"
    require_identity || return 3
    require_unmounted || return 3
    log "native compatibility profile=$COMPAT_PROFILE kernel=$KERNEL_GUARD"
    # Do not create authority for a disabled/not-yet-ready Wi-Fi service.
    preflight=$("$NATIVE" inspect-wlan 2>&1) || { log 'REJECT wlan_not_ready'; return 3; }
    case "$preflight" in
        *'"wifi":1,'*) ;;
        *) log 'REJECT wifi_must_be_enabled'; return 3 ;;
    esac
    if [ "${RUN_MODE:-persistent}" = persistent ]; then
        module_preflight=$("$NATIVE" inspect-module 2>&1) || {
            log 'REJECT module_control_not_ready'; return 3; }
        case "$module_preflight" in
            *'"status":"module_control_available"'*) ;;
            *) log 'REJECT module_control_invalid_reply'; return 3 ;;
        esac
    fi

    boot=$(boot_id)
    backup=$WORK/backup-$boot
    [ ! -L "$backup" ] && [ ! -L "$backup/wifi.cfg.stock" ] && [ ! -L "$backup/wlan.ko.stock" ] || {
        log 'REJECT backup_symlink'; return 3; }
    mkdir -p "$backup" || return 3
    chmod 0700 "$backup" || return 3
    [ -f "$backup/wifi.cfg.stock" ] || cp "$CFG" "$backup/wifi.cfg.stock" || return 3
    [ -f "$backup/wlan.ko.stock" ] || cp "$STOCK_KO" "$backup/wlan.ko.stock" || return 3
    [ "$(file_sha "$backup/wifi.cfg.stock")" = "$STOCK_CFG_SHA" ] || {
        log "REJECT backup_cfg_hash"; return 3; }
    [ "$(file_sha "$backup/wlan.ko.stock")" = "$STOCK_KO_SHA" ] || {
        log "REJECT backup_ko_hash"; return 3; }

    mkdir -p "$TXN_ROOT" || return 3
    [ ! -L "$TXN_ROOT" ] && [ -d "$TXN_ROOT" ] || return 3
    chmod 0700 "$TXN_ROOT" || return 3
    tx=$(mktemp -d "$TXN_ROOT/t-$(boot_id | cut -c1-8)-$(date +%s)-XXXXXX") || return 3
    chmod 0700 "$tx" || return 3
    boot_id >"$tx/wrapper-boot" || return 3
    write_active "$tx" || return 3

    if [ "${RUN_MODE:-persistent}" = persistent ]; then
        out=$("$NATIVE" run-wlan-persistent "$tx" 2>&1)
    else
        out=$("$NATIVE" run-wlan "$tx" 900000 2>&1)
    fi
    rc=$?
    printf '%s\n' "$out" >>"$tx/apply-wrapper.log"
    pid=$(printf '%s\n' "$out" | json_pid)
    case "$pid" in ''|*[!0-9]*) pid= ;; esac
    [ -z "$pid" ] || printf '%s\n' "$pid" >"$ACTIVE_PID_FILE"
    case "$out" in
        *'"status":"owned"'*) ;;
        *) log "FAIL native_run rc=$rc output=$out"; return 3 ;;
    esac
    [ "$rc" = 0 ] || { log "FAIL native_run rc=$rc"; return 3; }
    echo active >"$STATE"
    log "native transaction active tx=$tx guardian=$pid backup=$backup"
    printf '{"status":"active","tx":"%s","guardian_pid":%s}\n' "$tx" "$pid"
}

wait_terminal() {
    tx=$1
    i=0
    terminal_wait=100
    # A unified guardian must finish the bounded AP barrier before restoring
    # WLAN; do not report it stuck after the standalone100s grace period.
    [ "$MODULE_EMBEDDED" != 1 ] || terminal_wait=600
    while [ "$i" -lt "$terminal_wait" ]; do
        grep -q '"event":"terminal"' "$tx/guardian.log" 2>/dev/null && return 0
        guardian_alive "$tx" || return 1
        sleep 1
        i=$((i+1))
    done
    return 1
}

native_recover_retry() {
    attempt=0
    while :; do
        out=$("$NATIVE" recover "$tx" 2>&1)
        rc=$?
        [ "$rc" = 3 ] && [ "$out" = '{"status":"busy_or_invalid_lock"}' ] &&
            ! guardian_alive "$tx" || break
        [ "$attempt" -lt 15 ] || break
        attempt=$((attempt+1))
        sleep 1
    done
    printf '%s\n' "$out"
    return "$rc"
}

no_start_proven() {
    [ ! -e "$tx/prepared" ] && [ ! -L "$tx/prepared" ] &&
        [ ! -e "$tx/wlan-intent" ] && [ ! -L "$tx/wlan-intent" ] || return 1
    if grep '"event":"terminal"' "$tx/guardian.log" 2>/dev/null | grep -q '"restoration":"no_mount_effects"'; then
        return 0
    fi
    # Exact native refusals before fork/prepare. A failed parent lock creates no
    # guardlock; lock failures after guardlock creation remain ambiguous.
    [ ! -e "$tx/guardian.log" ] && [ ! -L "$tx/guardian.log" ] &&
        [ ! -e "$tx/guardlock" ] && [ ! -L "$tx/guardlock" ] &&
        [ ! -L "$tx/apply-wrapper.log" ] &&
        grep -Exq '\{"status":"(module_control_unavailable|busy_or_invalid_lock)"\}' "$tx/apply-wrapper.log" 2>/dev/null
}

cmd_restore() {
    need_native
    pid_authority_safe || { log 'REJECT active_pid_invalid'; return 90; }
    if tx=$(active_tx); then
        :
    else
        rc=$?
        [ "$rc" = 1 ] || { log 'REJECT active_tx_invalid'; return 90; }
        if require_identity && require_unmounted; then
            echo restored >"$STATE"
            log 'native idle: no active transaction'
            return 0
        fi
        echo restore_failed >"$STATE"
        log 'FAIL native idle_cfg_not_stock'
        return 90
    fi
    [ -d "$tx" ] || { echo restore_failed >"$STATE"; return 90; }
    [ ! -L "$tx/wrapper-boot" ] && [ -f "$tx/wrapper-boot" ] || {
        log 'REJECT missing_or_cross_boot_authority'; return 90; }
    restore_boot=$(cat "$tx/wrapper-boot" 2>/dev/null) || return 90
    if [ "$restore_boot" != "$(boot_id)" ]; then
        # Under control.sh's lock. Only retire old wrapper authority after
        # cmd_reconcile proves stock in both self and init namespaces.
        # Never replay an old boot's native journal against this kernel.
        cmd_reconcile || return 90
        [ ! -s "$ACTIVE_TX_FILE" ] || return 90
        echo restored >"$STATE" || return 90
        log 'native restore: cross-boot authority safely retired'
        printf '{"status":"restored","reason":"cross_boot_retired_stock"}\n'
        return 0
    fi
    if guardian_alive "$tx"; then
        "$NATIVE" cancel "$tx" >>"$tx/restore-wrapper.log" 2>&1 || {
            echo restore_failed >"$STATE"; return 90; }
    fi
    wait_terminal "$tx" || {
        if guardian_alive "$tx"; then
            echo restore_failed >"$STATE"
            log 'FAIL native guardian_did_not_terminate'
            return 90
        fi
        # No terminal after a crash: let native locks/journal decide recovery.
        log 'native guardian unavailable; attempting checked recovery'
    }
    if no_start_proven; then
        # The completed native prepare never published a mount or radio change.
        # Keep all files as evidence; only close this boot's wrapper authority.
        require_identity && require_unmounted && require_unmounted "$INIT_MOUNTINFO_FILE" || return 90
        [ "$(file_sha "$INIT_CFG_PATH")" = "$STOCK_CFG_SHA" ] || return 90
        clear_active || return 90
        echo restored >"$STATE"
        log "native unstarted transaction closed tx=$tx"
        return 0
    fi
    out=$(native_recover_retry)
    rc=$?
    printf '%s\n' "$out" >>"$tx/restore-wrapper.log"
    if [ "$rc" != 0 ]; then
        echo restore_failed >"$STATE"
        log "FAIL native_recover rc=$rc output=$out"
        # rc7 is post-restoration association/IPv4 readiness, not an initial
        # prerequisite for restoring mounts. Keep authority and failure status;
        # expose the distinction without claiming full recovery or reconnecting.
        if [ "$rc" = 7 ]; then
            log 'REJECT recovery_network_not_ready'
        fi
        return 90
    fi
    require_identity && require_unmounted || {
        echo restore_failed >"$STATE"; return 90; }
    clear_active || { echo restore_failed >"$STATE"; return 90; }
    echo restored >"$STATE"
    log "native restore done tx=$tx"
    printf '{"status":"restored"}\n'
}

case "${2:-}" in
    ready) need_native; "$NATIVE" inspect-wlan ;;
    inspect) cmd_inspect ;;
    status) cmd_status ;;
    apply) cmd_apply ;;
    restore) cmd_restore ;;
    *) echo 'usage: native.sh MODDIR ready|inspect|status|apply|restore' >&2; exit 64 ;;
esac
