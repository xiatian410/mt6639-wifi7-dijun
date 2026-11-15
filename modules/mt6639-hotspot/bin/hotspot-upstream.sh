#!/system/bin/sh
# Resolve an upstream without changing Wi-Fi. Print only the mode, never SSID.
set -u
request=${1:-auto} band=${2:-6g}
case "$request" in auto|wifi|wifi-any|cell) ;; *) echo 'REJECT bad_upstream_mode' >&2; exit 64 ;; esac
case "$band" in
    6g) upstream=LabNet-6G ;;
    2g|5g) upstream=LabNet-2.4G ;;
    *) exit 64 ;;
esac
if [ "$#" = 3 ]; then
    status=$(cat "$3") || exit 69
else
    status=$(timeout 5 cmd wifi status) || { echo 'REJECT sta_status_unavailable' >&2; exit 69; }
fi
printf '%s\n' "$status" | grep -Fxq 'Wifi is enabled' || {
    echo 'REJECT wifi_disabled_driver_unavailable' >&2; exit 69;
}
connected=0
if printf '%s\n' "$status" | grep -Fq 'Wifi is connected to "'; then
    printf '%s\n' "$status" | grep -Fq 'Supplicant state: COMPLETED' || {
        echo 'REJECT sta_connection_incomplete' >&2; exit 69;
    }
    connected=1
fi
if [ "$request" = auto ]; then
    if [ "$connected" = 0 ]; then
        request=cell
    elif printf '%s\n' "$status" | grep -Fxq "Wifi is connected to \"$upstream\""; then
        request=wifi
    else
        request=wifi-any
    fi
fi
case "$request:$connected" in
    cell:0|wifi:1|wifi-any:1) printf '%s\n' "$request" ;;
    *) echo 'REJECT upstream_connection_mismatch' >&2; exit 69 ;;
esac
