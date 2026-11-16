#!/bin/sh
# Build a new module ZIP from pinned candidate artifacts. No installation/restart.
set -eu
[ "$#" = 5 ] || [ "$#" = 6 ] || {
    echo 'usage: build_hotspot_module.sh HOSTAPD_BIN_DIR NATIVE_TETHER_DEX SOFTAP_PROFILE_DEX DELETE_IFINDEX_BIN OUTPUT_ZIP [WEBROOT_DIR]' >&2
    exit 64
}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
HOSTDIR=$(CDPATH= cd -- "$1" && pwd)
NATIVE_DEX=$2
PROFILE_DEX=$3
DELETE_IFINDEX=$4
OUT=$5
# Optional console built by tools/build_webui.sh. Without it the module is
# complete but has no WebUI; the build never fetches or compiles anything.
WEBROOT=${6:-}
SOURCE=$ROOT/modules/mt6639-hotspot

[ -f "$HOSTDIR/hostapd" ] && [ -f "$HOSTDIR/hostapd_cli" ] || exit 66
[ -f "$NATIVE_DEX" ] && [ -f "$PROFILE_DEX" ] && [ -f "$DELETE_IFINDEX" ] || exit 66
[ ! -e "$OUT" ] || { echo 'REJECT output_exists' >&2; exit 73; }
if [ -n "$WEBROOT" ]; then
    WEBROOT=$(CDPATH= cd -- "$WEBROOT" && pwd) || exit 66
    for f in index.html console.js bridge.js WEBUI-PROVENANCE.txt; do
        [ -f "$WEBROOT/$f" ] && [ ! -L "$WEBROOT/$f" ] || {
            echo "REJECT webroot_incomplete missing=$f" >&2; exit 66; }
    done
    ls "$WEBROOT"/*.wasm >/dev/null 2>&1 || { echo 'REJECT webroot_incomplete missing=wasm' >&2; exit 66; }
    if find "$WEBROOT" -type l | grep -q .; then
        echo 'REJECT symlink_in_webroot' >&2; exit 69
    fi
fi
file_sha() { sha256sum "$1" | awk '{print $1}'; }
expect() {
    actual=$(file_sha "$2")
    [ "$actual" = "$1" ] || {
        echo "REJECT sha256_mismatch path=$2 expected=$1 actual=$actual" >&2
        exit 69
    }
}
expect 15023e3bfe6b08415ebcc92479c0cd4fb14adb57b9010266af73bcc1bdc7bc2b "$HOSTDIR/hostapd"
expect 2da7d467b7b2628c4da40fb5ccc101b17f8b279bd9c038c32e4ae6e5b2924a42 "$HOSTDIR/hostapd_cli"
expect 71c2ff994fcc2f2ede23eeb361b9d153d9a72c00240ad90c677deb23827fea56 "$NATIVE_DEX"
expect d20169f8733dc3bd2813806b3deda79e84b497e40e4a0f82bb97cd585844d655 "$DELETE_IFINDEX"
expect 7ff17f05008e77535dacac13c5c2f216c664bc26403d6cbfe7da7fb9b7c04017 "$PROFILE_DEX"
expect c1a0024f795f800eea6ac7566f6aeb0f159cb4082b73fac2e5be92927eaff0ba "$ROOT/tools/softap_native_config.sh"
expect db04571066007be1de906faba90ba4abeee88ae83df59e3ec8b2508a09424500 "$ROOT/tools/ssid_hex.sh"
expect baaec1e35a868bfc5993191c0e391283b20c2f0fc3f6b269ec718ca5b3dab573 "$ROOT/tools/twt_recover.sh"

PARENT=$(dirname -- "$OUT")
mkdir -p "$PARENT"
PARENT=$(CDPATH= cd -- "$PARENT" && pwd)
OUT=$PARENT/$(basename -- "$OUT")
TMP=$(mktemp -d "$PARENT/.hotspot-module.XXXXXX")
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -r "$TMP"' EXIT HUP INT TERM
mkdir "$TMP/module"
cp -R "$SOURCE"/. "$TMP/module/"
cp "$SOURCE/module.prop" "$TMP/module/module.prop.template"
mkdir -p "$TMP/module/bin"
# Reuse the reviewed kernel/driver table and parser, not an OTA display version.
cp "$ROOT/modules/mt6639-6g/bin/compat.sh" "$TMP/module/bin/compat.sh"
cp "$ROOT/modules/mt6639-6g/compatibility.conf" "$TMP/module/bin/compatibility.conf"
cp "$HOSTDIR/hostapd" "$HOSTDIR/hostapd_cli" "$TMP/module/bin/"
cp "$DELETE_IFINDEX" "$TMP/module/bin/delete_ifindex"
cp "$ROOT/tools/softap_native_once.sh" "$ROOT/tools/softap_native_config.sh" "$ROOT/tools/ssid_hex.sh" \
    "$ROOT/tools/twt_recover.sh" "$TMP/module/bin/"
cp "$ROOT/tools/softap_once.sh" "$ROOT/tools/softap_profile.sh" "$TMP/module/bin/"
cp "$NATIVE_DEX" "$TMP/module/bin/native-tether.dex"
cp "$PROFILE_DEX" "$TMP/module/bin/softap-profile.dex"
if [ -n "$WEBROOT" ]; then
    mkdir "$TMP/module/webroot"
    cp -R "$WEBROOT"/. "$TMP/module/webroot/"
    find "$TMP/module/webroot" -type d -exec chmod 0755 {} +
    find "$TMP/module/webroot" -type f -exec chmod 0644 {} +
fi
chmod 0755 "$TMP/module/customize.sh" "$TMP/module/action.sh" "$TMP/module/service.sh" \
    "$TMP/module/uninstall.sh" "$TMP/module/bin/control.sh" "$TMP/module/bin/status_snapshot.sh" \
    "$TMP/module/bin/radio-control.sh" "$TMP/module/bin/radio-key.sh" \
    "$TMP/module/bin/radio-name.sh" "$TMP/module/bin/ssid_hex.sh" \
    "$TMP/module/bin/request_worker.sh" "$TMP/module/bin/android-env.sh" \
    "$TMP/module/bin/status-card.sh" "$TMP/module/bin/verify-module.sh" \
    "$TMP/module/bin/hotspot-identity.sh" "$TMP/module/bin/hotspot-upstream.sh" \
    "$TMP/module/bin/softap_native_once.sh" "$TMP/module/bin/softap_native_config.sh" \
    "$TMP/module/bin/softap_once.sh" "$TMP/module/bin/softap_profile.sh" \
    "$TMP/module/bin/softap_24g_once.sh" \
    "$TMP/module/bin/twt_recover.sh" "$TMP/module/bin/hostapd" "$TMP/module/bin/hostapd_cli"
chmod 0755 "$TMP/module/bin/delete_ifindex"
chmod 0644 "$TMP/module/bin/native-tether.dex" "$TMP/module/bin/softap-profile.dex"

if find "$TMP/module" -type l | grep -q .; then
    echo 'REJECT symlink_in_module' >&2
    exit 69
fi
if grep -R -n -E 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY|(gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{24,}' \
    "$TMP/module" >/dev/null 2>&1; then
    echo 'REJECT credential_pattern_in_module' >&2
    exit 69
fi

(
    cd "$TMP/module"
    # KernelSU removes customize.sh after sourcing it during installation.
    # Runtime integrity covers files retained by the installer only.
    {
        find bin -type f -print
        # The console issues root commands, so it is covered like the scripts.
        [ ! -d webroot ] || find webroot -type f -print
        printf '%s\n' module.prop.template action.sh service.sh uninstall.sh
    } | LC_ALL=C sort | xargs sha256sum > SHA256SUMS
)
{
    echo "source_commit=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "hostapd=$(file_sha "$HOSTDIR/hostapd")"
    echo "hostapd_cli=$(file_sha "$HOSTDIR/hostapd_cli")"
    echo "native_tether_dex=$(file_sha "$NATIVE_DEX")"
    echo "delete_ifindex=$(file_sha "$DELETE_IFINDEX")"
    echo "softap_profile_dex=$(file_sha "$PROFILE_DEX")"
    echo "default_autostart=0"
    if [ -n "$WEBROOT" ]; then
        echo "webui=$(cd "$WEBROOT" && find . -type f -print | LC_ALL=C sort | xargs sha256sum | sha256sum | awk '{print $1}')"
        sed 's/^/webui_/' "$WEBROOT/WEBUI-PROVENANCE.txt"
    else
        echo "webui=absent"
    fi
} > "$TMP/module/ASSET-PROVENANCE.txt"

# File mtimes are part of the ZIP records. Pin them and feed a C-sorted explicit
# file list so two clean builds of the same source tree are byte-identical.
find "$TMP/module" -type f -exec touch -t 198001010000.00 {} +
(
    cd "$TMP/module"
    find . -type f -print | sed 's|^\./||' | LC_ALL=C sort |
        zip -q -X "$TMP/module.zip" -@
)
mv "$TMP/module.zip" "$OUT"
trap - EXIT HUP INT TERM
chmod -R u+w "$TMP"
rm -r "$TMP"
echo "BUILT $OUT size=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT")"
sha256sum "$OUT"
