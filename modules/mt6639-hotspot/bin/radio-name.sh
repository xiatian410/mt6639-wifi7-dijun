#!/system/bin/sh
# Next-start-only SSID preference. No radio commands; custom names remain hex
# in storage, task staging and hostapd configuration, never shell source.
set -u
umask 077
MODDIR=${1:-/data/adb/modules/mt6639-hotspot}
OP=${2:-status}
case "$MODDIR" in /data/adb/modules/mt6639-hotspot) ;; *) exit 64 ;; esac
[ "$#" -le 2 ] || exit 64
case "$OP" in status|set) ;; *) echo 'usage: radio-name.sh MODDIR status|set' >&2; exit 64 ;; esac
[ "$(id -u)" = 0 ] && [ "$(id -Z)" = u:r:ksu:s0 ] || exit 77
[ -d "$MODDIR" ] && [ ! -L "$MODDIR" ] || exit 66
WORK=/data/adb/mt6639-hotspot
PRIVATE=$WORK/private
NAME=$PRIVATE/ap.ssid.hex
reject() { printf 'REJECT %s\n' "$1" >&2; exit "$2"; }
private_ok() {
    [ -d "$1" ] && [ ! -L "$1" ] &&
        [ "$(stat -c %u "$1")" = 0 ] && [ "$(stat -c %a "$1")" = 700 ]
}
private_dir() {
    [ ! -L "$1" ] || return 77
    if [ ! -e "$1" ]; then mkdir -m 0700 "$1" || return 74; fi
    [ -d "$1" ] && [ "$(stat -c %u "$1")" = 0 ] || return 77
    chmod 0700 "$1" || return 74
    private_ok "$1" || return 77
}
work_parent=${WORK%/*}
[ -d "$work_parent" ] && [ ! -L "$work_parent" ] &&
    [ "$(stat -c %u "$work_parent")" = 0 ] || reject work_directory_not_private 77
if [ "$OP" = status ]; then
    # Missing preference means the original band/width-derived default, but
    # unsafe or corrupt existing state is an error, not a silent reset.
    for dir in "$WORK" "$PRIVATE"; do
        [ -e "$dir" ] || [ -L "$dir" ] || { echo ssid_hex=; exit 0; }
        private_ok "$dir" || reject name_directory_invalid 77
    done
    [ -e "$NAME" ] || [ -L "$NAME" ] || { echo ssid_hex=; exit 0; }
    [ -f "$NAME" ] && [ ! -L "$NAME" ] &&
        [ "$(stat -c %u "$NAME")" = 0 ] && [ "$(stat -c %a "$NAME")" = 600 ] &&
        [ "$(stat -c %s "$NAME")" -le 65 ] || reject name_file_invalid 66
    hex=$(sh "$MODDIR/bin/ssid_hex.sh" < "$NAME") || reject name_encoding_invalid 65
    printf 'ssid_hex=%s\n' "$hex"
    exit 0
fi
private_dir "$WORK" || reject work_directory_not_private "$?"
private_dir "$PRIVATE" || reject private_directory_invalid "$?"
[ ! -L "$NAME" ] && { [ ! -e "$NAME" ] || [ -f "$NAME" ]; } || reject name_file_invalid 66
tmp=$(mktemp "$PRIVATE/.ap.ssid.hex.XXXXXX") || reject name_unwritable 74
trap 'rm -f "$tmp"' EXIT
trap 'exit 143' HUP INT TERM
sh "$MODDIR/bin/ssid_hex.sh" > "$tmp" || reject name_encoding_invalid 65
chmod 0600 "$tmp" && mv -f "$tmp" "$NAME" || reject name_unwritable 74
trap - EXIT HUP INT TERM
printf 'ssid_hex=%s\n' "$(cat "$NAME")"
