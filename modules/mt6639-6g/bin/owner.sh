#!/system/bin/sh
# The same backend ships standalone or under the unified module's fixed /six.
# Never trust an inherited MODULE_OWNER to redirect production ownership.
MODULE_OWNER=$MODDIR
MODULE_EMBEDDED=0
case "$MODDIR" in
    /data/adb/modules/mt6639-hotspot/six)
        MODULE_OWNER=/data/adb/modules/mt6639-hotspot
        MODULE_EMBEDDED=1
        ;;
esac
if [ "${MT6639_TEST_MODE:-0}" = 1 ] && [ -n "${MT6639_TEST_MODULE_OWNER:-}" ]; then
    [ "$MODDIR" = "$MT6639_TEST_MODULE_OWNER/six" ] || {
        echo 'REJECT embedded_fixture_path' >&2; exit 3;
    }
    MODULE_OWNER=$MT6639_TEST_MODULE_OWNER
    MODULE_EMBEDDED=1
fi

require_owner_mutation() {
    [ "$MODULE_EMBEDDED" = 1 ] || return 0
    # Run before reconcile can mistake an old-install guardian for a dead one.
    # The owner guard rejects legacy modules and the install's own boot.
    sh "$MODULE_OWNER/bin/unified-guard.sh" "$MODULE_OWNER" check || return 3
    sh "$MODULE_OWNER/bin/verify-module.sh" "$MODULE_OWNER" || return 3
}

require_owner_enabled() {
    if [ -e "$MODULE_OWNER/disable" ] || [ -L "$MODULE_OWNER/disable" ] ||
       [ -e "$MODULE_OWNER/remove" ] || [ -L "$MODULE_OWNER/remove" ]; then
        echo 'REJECT module_disabled_or_removing' >&2
        return 3
    fi
}
