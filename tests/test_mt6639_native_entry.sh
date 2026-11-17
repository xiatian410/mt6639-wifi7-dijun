#!/bin/sh
# Tests the production module wrapper with a contract-level fake executor.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
MOD=$ROOT/modules/mt6639-6g
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
bad() { fail=$((fail+1)); echo "FAIL $1"; }

setup() {
    rm -rf "$TMP/work" "$TMP/etc" "$TMP/bin"
    mkdir -p "$TMP/work" "$TMP/etc" "$TMP/bin" "$TMP/stub"
    printf '#!/bin/sh\n[ "$1" = -u ] && { echo 0; exit 0; }\nexec /usr/bin/id "$@"\n' >"$TMP/stub/id"
    chmod +x "$TMP/stub/id"
    printf 'CountryCode=CN\nDisallowBand6G 1\n' >"$TMP/etc/wifi.cfg"
    printf 'ko\n' >"$TMP/etc/wlan.ko"
    printf 'boot-native-1\n' >"$TMP/boot"
    export MT6639_TEST_MODE=1 CFG=$TMP/etc/wifi.cfg STOCK_KO=$TMP/etc/wlan.ko
    export STOCK_CFG_SHA=$(sha256sum "$CFG" | cut -d' ' -f1)
    export STOCK_KO_SHA=$(sha256sum "$STOCK_KO" | cut -d' ' -f1)
    export WORK=$TMP/work BOOT_ID_FILE=$TMP/boot MOUNTINFO_FILE=$TMP/mountinfo
    export NATIVE=$TMP/bin/mount-txn
    export PATH=$TMP/stub:$PATH
    : >"$TMP/mountinfo"
    : >"$TMP/calls"
}

common_env() {
    setup
    cat >"$NATIVE" <<'EOF'
#!/bin/sh
echo "$*" >>"$NATIVE_CALLS"
case "$1" in
inspect) echo '{"uid":0}' ;;
inspect-module) echo '{"status":"module_control_available","read_only":true,"module_state":"enabled"}' ;;
inspect-wlan) echo '{"scan":1,"wifi":1,"read_only":true}' ;;
run-wlan|run-wlan-persistent)
    tx=$2; printf '%s\n' '{"status":"owned","guardian_pid":999999}'
    printf '%s\n' '{"event":"terminal","operation":"deadline","restoration":"restored"}' >"$tx/guardian.log" ;;
cancel) echo '{"status":"cancel_requested"}' ;;
recover)
    if [ "${FAKE_RECOVER_RC:-0}" != 0 ]; then echo '{"status":"network_not_ready"}'; exit "$FAKE_RECOVER_RC"; fi
    echo '{"status":"idle","restoration":"restored"}' ;;
esac
EOF
    chmod +x "$NATIVE"
    export NATIVE_CALLS=$TMP/calls
    export ENABLE_6G=1
}

common_env
unset ENABLE_6G
run_status=0; sh "$MOD/bin/native.sh" "$MOD" apply >"$TMP/out" 2>&1 || run_status=$?
[ "$run_status" = 0 ] && [ -s "$WORK/active_tx" ] && grep -q '"status":"active"' "$TMP/out" &&
    ok 'unset switch enables a guarded transaction by default' || bad 'unset switch enables a guarded transaction by default'

common_env
ENABLE_6G=0 run_status=0
ENABLE_6G=0 sh "$MOD/bin/native.sh" "$MOD" apply >"$TMP/out" 2>&1 || run_status=$?
[ "$run_status" = 0 ] && [ ! -s "$NATIVE_CALLS" ] && ok 'explicit off makes no native calls' || bad 'explicit off makes no native calls'

common_env
printf '%s\n' "$WORK/transactions/t-bad/../../foreign" >"$WORK/active_tx"
run_status=0; sh "$MOD/bin/native.sh" "$MOD" apply >"$TMP/out" 2>&1 || run_status=$?
[ "$run_status" = 3 ] && [ ! -s "$NATIVE_CALLS" ] && [ -s "$WORK/active_tx" ] &&
    ok 'malformed authority blocks apply without native calls' || bad 'malformed authority blocks apply without native calls'
run_status=0; sh "$MOD/bin/native.sh" "$MOD" restore >"$TMP/out" 2>&1 || run_status=$?
[ "$run_status" = 90 ] && [ ! -s "$NATIVE_CALLS" ] && [ -s "$WORK/active_tx" ] &&
    ok 'malformed authority blocks restore and is preserved' || bad 'malformed authority blocks restore and is preserved'

common_env
printf '%s\n' /foreign/transaction >"$WORK/active_tx"
run_status=0; sh "$MOD/bin/native.sh" "$MOD" restore >"$TMP/out" 2>&1 || run_status=$?
[ "$run_status" = 90 ] && [ -s "$WORK/active_tx" ] &&
    ok 'foreign authority is not treated as idle' || bad 'foreign authority is not treated as idle'

common_env
: >"$WORK/active_tx"
run_status=0; sh "$MOD/bin/native.sh" "$MOD" apply >"$TMP/out" 2>&1 || run_status=$?
[ "$run_status" = 0 ] && [ -s "$WORK/active_tx" ] &&
    ok 'cleared authority permits a new transaction' || bad 'cleared authority permits a new transaction'

common_env
unlink "$NATIVE"
run_status=0; sh "$MOD/bin/native.sh" "$MOD" apply >"$TMP/out" 2>&1 || run_status=$?
[ "$run_status" = 3 ] && [ ! -e "$WORK/active_tx" ] && ok 'missing native rejects' || bad 'missing native rejects'

common_env
chmod 0644 "$NATIVE"
run_status=0; sh "$MOD/bin/native.sh" "$MOD" apply >"$TMP/out" 2>&1 || run_status=$?
[ "$run_status" = 0 ] && [ -x "$NATIVE" ] && grep -q '"status":"active"' "$TMP/out" &&
    ok 'non-executable packaged native is repaired' || bad 'non-executable packaged native is repaired'

common_env
run_status=0; sh "$MOD/bin/native.sh" "$MOD" apply >"$TMP/out" 2>&1 || run_status=$?
[ "$run_status" = 0 ] && grep -q '"status":"active"' "$TMP/out" && ok 'apply records owned transaction' || bad 'apply records owned transaction'
[ -s "$WORK/active_tx" ] && [ -s "$WORK/active_pid" ] && ok 'apply persists active authority' || bad 'apply persists active authority'
[ "$(sha256sum "$CFG" | cut -d' ' -f1)" = "$STOCK_CFG_SHA" ] && ok 'apply leaves caller-owned cfg' || bad 'apply leaves caller-owned cfg'
[ -n "$(find "$WORK" -name wifi.cfg.stock -type f)" ] && ok 'apply creates device backup' || bad 'apply creates device backup'

run_status=0; sh "$MOD/bin/native.sh" "$MOD" apply >"$TMP/out" 2>&1 || run_status=$?
[ "$run_status" = 0 ] && grep -q 'native restore done' "$WORK/apply.log" && ok 'second apply reconciles completed guardian' || bad 'second apply reconciles completed guardian'

run_status=0; sh "$MOD/bin/native.sh" "$MOD" restore >"$TMP/out" 2>&1 || run_status=$?
[ "$run_status" = 0 ] && grep -q '"status":"restored"' "$TMP/out" && ok 'restore delegates and completes' || bad 'restore delegates and completes'
[ ! -s "$WORK/active_tx" ] && [ "$(cat "$WORK/state")" = restored ] && ok 'restore clears active authority' || bad 'restore clears active authority'

common_env
sh "$MOD/bin/native.sh" "$MOD" apply >/dev/null 2>&1
run_status=0; FAKE_RECOVER_RC=7 sh "$MOD/bin/native.sh" "$MOD" restore >"$TMP/out" 2>&1 || run_status=$?
[ "$run_status" = 90 ] && [ -s "$WORK/active_tx" ] && [ "$(cat "$WORK/state")" = restore_failed ] &&
    grep -q 'REJECT recovery_network_not_ready$' "$TMP/out" &&
    ok 'business-not-ready retains active recovery authority' || bad 'business-not-ready retains active recovery authority'

echo
echo "RESULT pass=$pass fail=$fail"
[ "$fail" = 0 ]
