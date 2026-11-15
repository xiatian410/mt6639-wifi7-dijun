#!/system/bin/sh
# Select the active Bluetooth component, independent of the OTA display build.
# The caller checks the device/root context. No file paths are sourced as code.
select_bluetooth_component() {
    BT_PROFILE=unsupported
    BT_ERROR=
    BT_APK=none
    BT_APK_SHA=unreadable
    [ "$(getprop ro.build.version.sdk)" = 37 ] || { BT_ERROR=unsupported_sdk; return 1; }
    apk_count=0
    for candidate in /apex/com.android.bt/app/Bluetooth*/Bluetooth.apk; do
        [ -f "$candidate" ] || continue
        BT_APK=$candidate
        apk_count=$((apk_count+1))
    done
    [ "$apk_count" = 1 ] || { BT_ERROR=missing_or_ambiguous_bluetooth_apk; return 1; }
    apk_hash=$(sha256sum "$BT_APK" 2>/dev/null) || { BT_ERROR=unreadable_bluetooth_apk; return 1; }
    BT_APK_SHA=${apk_hash%% *}
    case "$BT_APK_SHA" in
        22f2e2ac8c036f7716e792f1fa54d7f5c3dd53754cb3c01db93ee3981cd34339) BT_PROFILE=os4-initial ;;
        1a5ae65ccd8621c03ca5a6a035979eac74025c3ecdda19dd84f1bbd53162983e) BT_PROFILE=os4-stable ;;
        *) BT_ERROR=unsupported_bluetooth_apk; return 1 ;;
    esac
}
