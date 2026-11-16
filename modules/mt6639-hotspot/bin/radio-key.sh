#!/system/bin/sh
# Install the hotspot passphrase for the console.
#
# The passphrase is never placed in a command line, a log or this script's
# output: `set` reads one line of lowercase hex from standard input, and
# `status` reports only whether a usable key file exists.
set -u
umask 077

MODDIR=${1:-/data/adb/modules/mt6639-hotspot}
OP=${2:-status}
case "$MODDIR" in /data/adb/modules/mt6639-hotspot) ;; *) exit 64 ;; esac
[ "$#" -le 2 ] || exit 64
case "$OP" in status|set) ;; *) echo 'usage: radio-key.sh MODDIR status|set' >&2; exit 64 ;; esac
[ "$(id -u)" = 0 ] && [ "$(id -Z)" = u:r:ksu:s0 ] || exit 77
[ -d "$MODDIR" ] && [ ! -L "$MODDIR" ] || exit 66

WORK=/data/adb/mt6639-hotspot
PRIVATE=$WORK/private
KEY=$PRIVATE/ap.key

key_ok() {
    [ -d "$PRIVATE" ] && [ ! -L "$PRIVATE" ] && [ -f "$KEY" ] && [ ! -L "$KEY" ] &&
        [ "$(stat -c %u "$KEY")" = 0 ] && [ "$(stat -c %a "$KEY")" = 600 ]
}
if [ "$OP" = status ]; then
    if key_ok; then echo ap_key=1; else echo ap_key=0; fi
    exit 0
fi

reject() { printf 'REJECT %s\n' "$1" >&2; exit "$2"; }
# Same directory rules as the hotspot controller; never follow a link.
private_dir() {
    [ ! -L "$1" ] || return 77
    if [ ! -e "$1" ]; then mkdir -m 0700 "$1" || return 74; fi
    [ -d "$1" ] && [ "$(stat -c %u "$1")" = 0 ] || return 77
    chmod 0700 "$1" || return 74
    [ "$(stat -c %a "$1")" = 700 ] || return 77
}
work_parent=${WORK%/*}
[ -d "$work_parent" ] && [ ! -L "$work_parent" ] &&
    [ "$(stat -c %u "$work_parent")" = 0 ] || reject work_directory_not_private 77
private_dir "$WORK" || reject work_directory_not_private "$?"
private_dir "$PRIVATE" || reject private_directory_invalid "$?"

IFS= read -r hex || [ -n "${hex:-}" ] || reject key_input_missing 65
case "$hex" in ''|*[!0-9a-f]*) reject key_encoding_invalid 65 ;; esac
# 8..63 characters, two hex digits each.
[ "$(( ${#hex} % 2 ))" = 0 ] && [ "${#hex}" -ge 16 ] && [ "${#hex}" -le 126 ] ||
    reject key_length_invalid 65

tmp=$(mktemp "$PRIVATE/.ap.key.XXXXXX") || reject key_unwritable 74
trap 'rm -f "$tmp"' EXIT
trap 'exit 143' HUP INT TERM
# echo is a shell builtin, so the digits stay out of every argument vector.
# Only printable ASCII is accepted, which is what hostapd's WPA passphrase
# and the module's own configuration check allow.
echo "$hex" | LC_ALL=C awk '
    BEGIN { digits = "0123456789abcdef" }
    {
        out = ""
        for (i = 1; i <= length($0); i += 2) {
            high = index(digits, substr($0, i, 1)) - 1
            low = index(digits, substr($0, i + 1, 1)) - 1
            code = high * 16 + low
            if (code < 32 || code > 126) exit 1
            out = out sprintf("%c", code)
        }
        print out
    }' > "$tmp" || reject key_characters_invalid 65
# The check softap_native_config.sh applies before it renders a profile.
LC_ALL=C awk 'NR != 1 || length($0) < 8 || length($0) > 63 || $0 ~ /[^ -~]/ { bad=1 }
    END { exit bad || NR != 1 }' "$tmp" || reject key_characters_invalid 65
chmod 0600 "$tmp" || reject key_unwritable 74
mv -f "$tmp" "$KEY" || reject key_unwritable 74
trap - EXIT HUP INT TERM
key_ok || reject key_not_installed 74
echo ap_key=1
