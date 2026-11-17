#!/system/bin/sh
# No wireless/process operations. Never adopt a legacy guardian in this boot.
set -u
MODDIR=${1:-/data/adb/modules/mt6639-hotspot}
OP=${2:-check}
case "$OP:$MODDIR" in
    check:/data/adb/modules/mt6639-hotspot|install:/data/adb/modules/mt6639-hotspot|install:/data/adb/modules_update/mt6639-hotspot) ;;
    *) exit 64 ;;
esac
reject() { printf 'REJECT %s\n' "$1" >&2; exit 73; }
[ "$(id -u)" = 0 ] || exit 77
# Even disabled or remove-marked legacy modules retain executable uninstall
# hooks targeting the SAME transaction store. They must finish removal first.
for legacy in /data/adb/modules/mt6639-6g /data/adb/modules_update/mt6639-6g; do
    [ ! -e "$legacy" ] && [ ! -L "$legacy" ] || reject legacy_six_module_present
done
[ -d "$MODDIR" ] && [ ! -L "$MODDIR" ] &&
    [ "$(stat -c %u "$MODDIR")" = 0 ] || reject unified_module_directory_invalid
boot=$(cat /proc/sys/kernel/random/boot_id) || reject unified_boot_unreadable
printf '%s\n' "$boot" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || reject unified_boot_unreadable
marker=$MODDIR/.unified-install-boot
if [ "$OP" = install ]; then
    # Installer writes only its own extracted module. No markers are written to
    # old modules and no authority/keys/journals are removed or rewritten.
    [ ! -L "$marker" ] && { [ ! -e "$marker" ] || [ -f "$marker" ]; } || reject unified_install_record_invalid
    umask 077
    tmp=$(mktemp "$MODDIR/.install-boot.XXXXXX") || exit 74
    trap 'rm -f "$tmp"' EXIT
    printf '%s\n' "$boot" > "$tmp" && chmod 0600 "$tmp" && mv -f "$tmp" "$marker" || exit 74
    trap - EXIT
    exit 0
fi
[ -f "$marker" ] && [ ! -L "$marker" ] &&
    [ "$(stat -c %u:%a:%s "$marker")" = 0:600:37 ] || reject unified_install_record_invalid
installed=$(cat "$marker") || reject unified_install_record_invalid
printf '%s\n' "$installed" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' || reject unified_install_record_invalid
[ "$installed" != "$boot" ] || reject unified_reboot_required
# A fresh boot plus no legacy lifecycle directories prevents an old executable
# from being treated as a dead relocated guardian. Existing cross-boot stock
# checks still decide whether old authority may be archived.
exit 0
