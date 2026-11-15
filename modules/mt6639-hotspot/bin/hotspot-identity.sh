#!/system/bin/sh
# Read-only native-hotspot identity gate. Recovery never calls this gate.
set -u
reject() { printf 'REJECT %s\n' "$1" >&2; exit 69; }
ASSETS=${1:-}
[ -d "$ASSETS" ] && [ ! -L "$ASSETS" ] || reject identity_assets_missing
for file in compat.sh compatibility.conf; do
    [ -f "$ASSETS/$file" ] && [ ! -L "$ASSETS/$file" ] || reject identity_assets_missing
done
[ "$(getprop ro.product.device)" = dijun ] || reject device_mismatch
[ "$(getprop ro.build.version.sdk)" = 37 ] || reject sdk_mismatch
KO=/vendor/lib/modules/wlan_drv_gen4m_eap_6639.ko
if [ ! -e "$KO" ] && [ ! -L "$KO" ]; then
    KO=/vendor_dlkm/lib/modules/wlan_drv_gen4m_eap_6639.ko
fi
observed=$(timeout 5 sha256sum "$KO" 2>/dev/null) || reject driver_unreadable
observed=${observed%% *}
release=$(uname -r) || reject kernel_unreadable
. "$ASSETS/compat.sh"
select_runtime_profile "$release" "$ASSETS/compatibility.conf" "$observed" || reject "$COMPAT_ERROR"
[ "$observed" = "$STOCK_KO_SHA" ] || reject driver_mismatch
printf 'compatibility_profile=%s driver=matched\n' "$COMPAT_PROFILE"
