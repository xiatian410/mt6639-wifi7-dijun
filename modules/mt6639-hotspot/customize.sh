#!/system/bin/sh
# KernelSU/Magisk module installer hook. ZIP extraction commonly normalizes
# executable bits to 0644, which prevents the module action button from running.
MODPATH=${MODPATH:-${0%/*}}
for f in action.sh service.sh uninstall.sh \
    bin/control.sh bin/status-card.sh bin/verify-module.sh bin/request_worker.sh bin/android-env.sh bin/delete_ifindex bin/status_snapshot.sh bin/softap_native_once.sh bin/softap_native_config.sh \
    bin/softap_once.sh bin/softap_profile.sh bin/softap_24g_once.sh \
    bin/twt_recover.sh bin/hostapd bin/hostapd_cli; do
    [ -f "$MODPATH/$f" ] && chmod 0755 "$MODPATH/$f"
done
true
