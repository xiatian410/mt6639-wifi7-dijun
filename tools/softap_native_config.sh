#!/bin/sh
# File-only, deterministic profiles; never calls a radio or changes country code.
set -eu
umask 077
[ "$#" = 4 ] || { echo 'usage: softap_native_config.sh TASK render|check|status 5g|6g WIDTH' >&2; exit 64; }
D=$1 OP=$2 BAND=$3 WIDTH=$4
case "$D" in /*) ;; *) exit 64 ;; esac
case "$D" in *[!a-zA-Z0-9/_-]*|*/../*|*/./*|*//*) exit 64 ;; esac
case "$OP" in render|check|status) ;; *) exit 64 ;; esac
case "$BAND:$WIDTH" in
    2g:20) CHANNEL=6 FREQ=2437 CLASS=81 CENTER=6 HE_CENTER=6 CHWIDTH=0 SECONDARY=0 ;;
    5g:20) CHANNEL=36 FREQ=5180 CLASS=115 CENTER=36 HE_CENTER=36 CHWIDTH=0 SECONDARY=0 ;;
    5g:40) CHANNEL=36 FREQ=5180 CLASS=116 CENTER=38 HE_CENTER=38 CHWIDTH=0 SECONDARY=1 ;;
    5g:80) CHANNEL=36 FREQ=5180 CLASS=128 CENTER=42 HE_CENTER=42 CHWIDTH=1 SECONDARY=1 ;;
    6g:20) CHANNEL=37 FREQ=6135 CLASS=131 CENTER=37 HE_CENTER=37 CHWIDTH=0 SECONDARY=0 ;;
    6g:40) CHANNEL=37 FREQ=6135 CLASS=132 CENTER=35 HE_CENTER=35 CHWIDTH=0 SECONDARY=-1 ;;
    6g:80) CHANNEL=37 FREQ=6135 CLASS=133 CENTER=39 HE_CENTER=39 CHWIDTH=1 SECONDARY=-1 ;;
    6g:160) CHANNEL=37 FREQ=6135 CLASS=134 CENTER=47 HE_CENTER=47 CHWIDTH=2 SECONDARY=-1 ;;
    6g:320) CHANNEL=37 FREQ=6135 CLASS=137 CENTER=31 HE_CENTER=47 CHWIDTH=4 SECONDARY=-1 ;;
    *) echo 'REJECT unsupported_band_width' >&2; exit 64 ;;
esac
HE_WIDTH=$CHWIDTH
[ "$WIDTH" != 320 ] || HE_WIDTH=2
# 2.4GHz is HE-only here: VHT does not exist on 2.4GHz and the C02 target is
# 11ax without EHT, which the radio probe proved this chip can do.
case "$BAND" in
    2g) HW_MODE=g EHT=0 ;;
    *) HW_MODE=a EHT=1 ;;
esac

if [ "$OP" = status ]; then
    [ -f "$D/status.active" ] && [ ! -L "$D/status.active" ] || exit 66
    # A parser success or ENABLED alone cannot prove the requested width.
    expected="state=ENABLED freq=$FREQ channel=$CHANNEL secondary_channel=$SECONDARY
hw_mode=$HW_MODE ieee80211ax=1 he_oper_chwidth=$HE_WIDTH
he_oper_centr_freq_seg0_idx=$HE_CENTER"
    if [ "$EHT" = 1 ]; then
        expected="$expected ieee80211be=1 eht_oper_chwidth=$CHWIDTH
eht_oper_centr_freq_seg0_idx=$CENTER"
    else
        expected="$expected ieee80211n=1 ieee80211be=0"
    fi
    for line in $expected; do
        key=${line%%=*}
        [ "$(grep -c "^$key=" "$D/status.active")" = 1 ] &&
            grep -Fxq "$line" "$D/status.active" || { echo "REJECT status_mismatch $key" >&2; exit 69; }
    done
    # Refuse ambiguous geometry, including a 6 GHz 40 MHz center with a cleared
    # secondary offset. This is native control state, not independent RF proof.
    echo "native_status=matched band=$BAND frequency_mhz=$FREQ width_mhz=$WIDTH center_index=$CENTER peer_unverified=1"
    exit 0
fi
[ -f "$D/ap.key" ] && [ ! -L "$D/ap.key" ] || exit 66
# Read through stdin, never put the passphrase into a child process argv.
# Limit to printable ASCII and 8..63 bytes for this diagnostic profile.
LC_ALL=C awk 'NR != 1 || length($0) < 8 || length($0) > 63 || $0 ~ /[^ -~]/ { bad=1 } END { exit bad || NR != 1 }' "$D/ap.key" || exit 65
KEY=$(cat "$D/ap.key")
SSID_LINE="ssid=MT6639-Native-$BAND-$WIDTH"
if [ -e "$D/ap.ssid.hex" ] || [ -L "$D/ap.ssid.hex" ]; then
    [ -f "$D/ap.ssid.hex" ] && [ ! -L "$D/ap.ssid.hex" ] &&
        [ "$(stat -c %s "$D/ap.ssid.hex")" -le 65 ] || exit 66
    SSID_HEX=$(sh "$(dirname "$0")/ssid_hex.sh" < "$D/ap.ssid.hex") || exit 65
    SSID_LINE="ssid2=$SSID_HEX"
fi
emit() {
    cat <<EOF
interface=mtap0
driver=nl80211
ctrl_interface=$D/ctrl
$SSID_LINE
hw_mode=$HW_MODE
op_class=$CLASS
channel=$CHANNEL
ieee80211n=1
EOF
    [ "$BAND" = 2g ] || echo 'ieee80211ac=1'
    echo 'ieee80211ax=1'
    [ "$EHT" != 1 ] || echo 'ieee80211be=1'
    if [ "$SECONDARY" = 1 ]; then echo 'ht_capab=[HT40+]'; fi
    if [ "$BAND" = 5g ]; then
        printf 'vht_oper_chwidth=%s\nvht_oper_centr_freq_seg0_idx=%s\n' "$HE_WIDTH" "$HE_CENTER"
    fi
    printf 'he_oper_chwidth=%s\nhe_oper_centr_freq_seg0_idx=%s\n' "$HE_WIDTH" "$HE_CENTER"
    [ "$EHT" != 1 ] ||
        printf 'eht_oper_chwidth=%s\neht_oper_centr_freq_seg0_idx=%s\n' "$CHWIDTH" "$CENTER"
    cat <<EOF
wpa=2
wpa_key_mgmt=SAE
rsn_pairwise=CCMP
ieee80211w=2
sae_pwe=1
EOF
    printf 'wpa_passphrase=%s\n' "$KEY"
}
if [ "$OP" = render ]; then emit; exit $?; fi
[ -f "$D/ap.conf" ] && [ ! -L "$D/ap.conf" ] || exit 66
# Exact comparison rejects duplicate keys, includes, country overrides and ACS.
emit | cmp -s - "$D/ap.conf" || { echo 'REJECT noncanonical_config' >&2; exit 69; }
echo "config_profile=matched band=$BAND frequency_mhz=$FREQ width_mhz=$WIDTH center_index=$CENTER radio_started=0"
