#!/system/bin/sh
# Installation does not operate WLAN or mark/kill/uninstall another module.
MODPATH=${MODPATH:-${0%/*}}
install_fail() {
    echo "MT6639: $*" >&2
    if command -v abort >/dev/null 2>&1; then abort "$*"; fi
    exit 73
}
# Old uninstall hooks share the transaction store: complete their uninstall and
# reboot BEFORE installing this bundle. Even disabled legacy dirs are refused.
for f in bin/unified-guard.sh bin/radio-teardown.sh six/bin/control.sh six/bin/mount-txn; do
    [ -f "$MODPATH/$f" ] && [ ! -L "$MODPATH/$f" ] || install_fail "incomplete unified module: $f"
done
sh "$MODPATH/bin/unified-guard.sh" "$MODPATH" install ||
    install_fail 'Remove the old mt6639-6g module and reboot first. No wireless changes were made by this installer.'
for f in action.sh service.sh uninstall.sh \
    bin/control.sh bin/radio-control.sh bin/radio-key.sh bin/radio-name.sh bin/ssid_hex.sh \
    bin/unified-guard.sh bin/radio-teardown.sh bin/status-card.sh bin/verify-module.sh \
    bin/hotspot-identity.sh bin/hotspot-upstream.sh bin/request_worker.sh bin/android-env.sh \
    bin/delete_ifindex bin/status_snapshot.sh bin/softap_native_once.sh bin/softap_native_config.sh \
    bin/softap_once.sh bin/softap_profile.sh bin/softap_24g_once.sh bin/twt_recover.sh \
    bin/hostapd bin/hostapd_cli; do
    [ -f "$MODPATH/$f" ] && chmod 0755 "$MODPATH/$f" || install_fail "permission setup failed: $f"
done
for f in "$MODPATH"/six/bin/*.sh "$MODPATH/six/bin/mount-txn"; do
    [ -f "$f" ] && [ ! -L "$f" ] && chmod 0755 "$f" || install_fail 'embedded backend permission setup failed'
done
echo 'MT6639: installed one module containing 6GHz + hotspot + WebUI; reboot before use.'
true
