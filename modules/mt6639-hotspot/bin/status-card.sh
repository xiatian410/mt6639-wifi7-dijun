#!/system/bin/sh
# Read-only observations and manager presentation. Never starts/stops a hotspot.
set -u
umask 077
MODDIR=${1:-/data/adb/modules/mt6639-hotspot}
MODE=${2:-show}
case "$MODDIR" in /data/adb/modules/mt6639-hotspot) ;; *) exit 64 ;; esac
case "$MODE" in show|update|poll) ;; *) exit 64 ;; esac
[ "$(id -u)" = 0 ] || exit 77
[ -d "$MODDIR" ] && [ ! -L "$MODDIR" ] || exit 77
for file in module.prop module.prop.template; do
    [ -f "$MODDIR/$file" ] && [ ! -L "$MODDIR/$file" ] || exit 77
    [ "$(grep -c '^description=' "$MODDIR/$file")" = 1 ] || exit 77
done
WORK=/data/adb/mt6639-hotspot
parent=${WORK%/*}
[ -d "$parent" ] && [ ! -L "$parent" ] && [ "$(stat -c %u "$parent")" = 0 ] || exit 77
[ ! -L "$WORK" ] || exit 77
if [ ! -e "$WORK" ]; then mkdir -m 0700 "$WORK" || exit 74; fi
[ -d "$WORK" ] && [ "$(stat -c %u "$WORK")" = 0 ] &&
    [ "$(stat -c %a "$WORK")" = 700 ] || exit 77
boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null) || exit 70
printf '%s\n' "$boot" | grep -Eq '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' || exit 70
write_record() {
    record_tmp=$(mktemp "$WORK/.card-record.XXXXXX") || return 1
    printf '%s\n%s\n' "$boot" "$2" > "$record_tmp" && mv -f "$record_tmp" "$WORK/$1"
}
# Keep the actual operation result even while a periodic renderer is busy.
if [ "$MODE" = update ] && [ "$#" = 4 ]; then
    case "$3" in start|stop|recover|toggle|c02-24g) ;; *) exit 64 ;; esac
    case "$4" in ''|*[!0-9]*) exit 64 ;; esac
    [ "$4" -le 255 ] || exit 64
    write_record card-event "$3:$4" || exit 74
    rm -f "$WORK/card-check"
fi
if [ "$MODE" = poll ]; then
    # Serialize the existing read-only controller status check with actions.
    # Skip while an action runs; snapshot publication still renders transitions.
    [ ! -L "$WORK/action.lock" ] || exit 77
    exec 7>"$WORK/action.lock" || exit 74
    flock -n 7 7>&7 || exit 0
    timeout 20 sh "$MODDIR/bin/control.sh" "$MODDIR" status 7>&- >/dev/null 2>&1
    check_rc=$?
    write_record card-check "$check_rc" || exit 74
    flock -u 7
    exec 7>&-
    MODE=update
fi
[ ! -L "$WORK/status-card.lock" ] || exit 77
exec 8>"$WORK/status-card.lock" || exit 74
flock -n 8 8>&8 || exit 0
snapshot=/data/misc/mt6639-hotspot/status
headline=状态不可用
band=未知
width=未知
key_status=未知
reconnect=未知
enforcing=未知
# Do not evaluate snapshot content as shell. Exact schema, keys and values only.
if [ -f "$snapshot" ] && [ ! -L "$snapshot" ] &&
   [ ! -L "${snapshot%/*}" ] && [ "$(stat -c %u "$snapshot")" = 0 ] &&
   [ "$(stat -c %s "$snapshot")" -le 4096 ] &&
   snapshot_mtime=$(stat -c %Y "$snapshot") &&
   snapshot_data=$(cat "$snapshot") &&
   printf '%s\n' "$snapshot_data" | awk -F= '
     NF != 2 || seen[$1]++ { exit 1 }
     $1 == "schema" { if ($2 != "mt6639-hotspot-status-v3") exit 1; next }
     $1 == "state" { if ($2 !~ /^(idle|starting|active|stopping|unresolved|disabled)$/) exit 1; next }
     $1 == "band" { if ($2 !~ /^(none|2g|5g|6g)$/) exit 1; next }
     $1 == "width" { if ($2 !~ /^(none|20|40|80|160|320)$/) exit 1; next }
     $1 == "boot" { next }
     $1 ~ /^(ap_key|reconnect_6g|reconnect_2g|enforcing|fiveg_upstream)$/ { if ($2 !~ /^[01]$/) exit 1; next }
     { exit 1 }
     END { if (NR != 10) exit 1 }
   '; then
    # Parse one captured publication; concurrent renames cannot mix states.
    field() { printf '%s\n' "$snapshot_data" | sed -n "s/^$1=//p"; }
    snapshot_boot=$(field boot)
    if [ "$snapshot_boot" = "$boot" ]; then
        mtime=$snapshot_mtime
        now=$(date +%s)
        case "$mtime:$now" in *[!0-9:]*) exit 70 ;; esac
        if [ "$mtime" -le "$((now+5))" ] && [ "$((now-mtime))" -le 90 ]; then
            state=$(field state)
            case "$state" in
                idle) headline=待启动 ;; starting) headline=启动中 ;;
                active) headline=热点运行 ;; stopping) headline=停止中 ;;
                unresolved) headline=需检查或恢复 ;; disabled) headline=模块已禁用 ;;
            esac
            case "$(field band)" in
                2g) band=2.4GHz ;; 5g) band=5GHz ;; 6g) band=6GHz ;; none) band=未设置 ;;
            esac
            width=$(field width)
            case "$width" in none) width=未设置 ;; *) width="${width}MHz" ;; esac
            key_status=缺失
            [ "$(field ap_key)" != 1 ] || key_status=已配置
            six=缺失; two=缺失
            [ "$(field reconnect_6g)" != 1 ] || six=有
            [ "$(field reconnect_2g)" != 1 ] || two=有
            reconnect="6G${six}/2G${two}"
            enforcing=非Enforcing
            [ "$(field enforcing)" != 1 ] || enforcing=Enforcing
        else
            headline=状态快照过期
        fi
    else
        headline=等待本次启动状态
    fi
fi
last=无
recovery=未记录
if [ -f "$WORK/card-event" ] && [ ! -L "$WORK/card-event" ] &&
   [ "$(sed -n '1p' "$WORK/card-event")" = "$boot" ]; then
    event=$(sed -n '2p' "$WORK/card-event")
    case "$event" in
        start:*) action=启动 ;; stop:*) action=停止 ;; recover:*) action=恢复 ;;
        toggle:*) action=切换 ;; c02-24g:*) action=验收 ;; *) action= ;;
    esac
    code=${event#*:}
    case "$code" in ''|*[!0-9]*) action= ;; esac
    if [ -n "$action" ]; then
        if [ "$code" = 0 ]; then last="${action}成功"; else last="${action}失败(rc=$code)"; fi
        case "$event" in
            stop:0|recover:0) recovery=成功 ;;
            stop:*|recover:*) recovery="失败(rc=$code)" ;;
        esac
    fi
fi
if [ -f "$WORK/card-check" ] && [ ! -L "$WORK/card-check" ] &&
   [ "$(sed -n '1p' "$WORK/card-check")" = "$boot" ] &&
   [ "$(sed -n '2p' "$WORK/card-check")" != 0 ]; then
    headline=状态检查失败
fi
[ ! -e "$MODDIR/disable" ] || headline=模块已禁用
[ ! -e "$MODDIR/remove" ] || headline=模块待移除
stamp=$(date '+%H:%M:%S')
description="[$headline] 频段：$band | 配置带宽：$width | 热点密钥：$key_status | 恢复配置：$reconnect | SELinux：$enforcing | 恢复：$recovery | 最近操作：$last | 更新：$stamp。状态检查不代表客户端联网。"
if [ "$MODE" = show ]; then printf '%s\n' "$description"; exit 0; fi
tmp=$(mktemp "$MODDIR/.module.prop.XXXXXX") || exit 74
trap 'rm -f "$tmp"' EXIT
trap 'exit 143' HUP INT TERM
awk -v description="$description" '
    /^description=/ { print "description=" description; next } { print }
' "$MODDIR/module.prop.template" > "$tmp" || exit 74
chmod 0644 "$tmp" || exit 74
mv -f "$tmp" "$MODDIR/module.prop" || exit 74
