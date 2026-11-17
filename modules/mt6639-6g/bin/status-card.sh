#!/system/bin/sh
# Observe only. No country setters, Wi-Fi toggles, mount changes or recovery.
# The manager reloads module.prop when its module list is refreshed/reopened.
set -u
MODDIR=${1:-/data/adb/modules/mt6639-6g}
MODE=${2:-show}
case "$MODE" in show|update) ;; *) exit 64 ;; esac
. "$MODDIR/bin/lib.sh"
# Embedded six has no module identity/card of its own. Only the owner renders
# module.prop; keep show available as a summary without requiring six metadata.
if [ "$MODULE_EMBEDDED" = 1 ] && [ "$MODE" = update ]; then exit 0; fi
TEMPLATE=$MODDIR/module.prop.template
if [ "$MODULE_EMBEDDED" != 1 ]; then
    [ -f "$TEMPLATE" ] && [ ! -L "$TEMPLATE" ] || exit 3
    [ -f "$MODDIR/module.prop" ] && [ ! -L "$MODDIR/module.prop" ] || exit 3
fi

now_boot=$(boot_id)
[ -n "$now_boot" ] || exit 3
if [ "$MODE" = update ] && [ "$#" = 4 ]; then
    case "$3:$4" in
        enable:0|disable:0|refresh:0) event="$3:ok" ;;
        enable:*|disable:*|refresh:*) event="$3:failed" ;;
        *) exit 64 ;;
    esac
    event_tmp=$(mktemp "$WORK/.card-event.XXXXXX") || exit 3
    printf '%s\n%s\n' "$now_boot" "$event" >"$event_tmp"
    mv -f "$event_tmp" "$WORK/card-event" || exit 3
fi
# Publish the serialized operation result even if a periodic renderer is busy.
# Nonblocking presentation lock; never take the management/transaction lock.
exec 7>"$WORK/status-card.lock" || exit 3
flock -n 7 7>&7 || exit 0

kernel=匹配
[ "$(uname -r)" = "$KERNEL_GUARD" ] || kernel=不匹配
driver=匹配
driver_sha=$(file_sha "$STOCK_KO")
if [ -z "$driver_sha" ]; then
    driver=不可读
elif [ "$driver_sha" != "$STOCK_KO_SHA" ]; then
    driver=哈希不匹配
fi
cfg=原厂
[ "$(file_sha "$CFG")" = "$STOCK_CFG_SHA" ] || cfg=变更或不可读
transaction=空闲
headline=待启用
runtime=$(timeout 3 sh "$MODDIR/bin/native.sh" "$MODDIR" status 7>&- 2>/dev/null)
runtime_rc=$?
if [ "$runtime_rc" != 0 ]; then
    transaction=未知
    headline=状态读取失败
elif printf '%s\n' "$runtime" | grep -qx 'state=active' &&
     printf '%s\n' "$runtime" | grep -qx 'guardian=alive'; then
    transaction=运行
    headline=事务运行
elif ! printf '%s\n' "$runtime" | grep -qx 'active_tx=none'; then
    transaction=待核对
    headline=事务需核对
elif printf '%s\n' "$runtime" | grep -qx 'state=restored'; then
    headline=已恢复
elif printf '%s\n' "$runtime" | grep -qx 'enabled_config=0'; then
    headline=默认关闭
fi
if [ "$transaction" = 运行 ]; then
    tx=$(printf '%s\n' "$runtime" | sed -n 's/^active_tx=//p' | head -1)
    suffix=${tx#"$WORK/transactions/t-"}
    case "$tx:$suffix" in
        "$WORK"/transactions/t-*:*)
            case "$suffix" in
                ''|*[!a-zA-Z0-9-]*) ;;
                *)
                    if [ -d "$tx" ] && [ ! -L "$tx" ] &&
                       [ "$(cat "$tx/wrapper-boot" 2>/dev/null)" = "$now_boot" ] &&
                       [ "$(file_sha "$CFG")" = "$(file_sha "$tx/candidate")" ] &&
                       [ -s "$tx/candidate" ] &&
                       awk -v target="$CFG" '$5 == target { n++ } END { exit(n ? 0 : 1) }' "$MOUNTINFO_FILE" 2>/dev/null; then
                        cfg=临时配置
                    fi
                    ;;
            esac
            ;;
    esac
fi
if [ -f "$WORK/card-event" ] && [ ! -L "$WORK/card-event" ] &&
   [ "$(sed -n '1p' "$WORK/card-event")" = "$now_boot" ]; then
    case "$(sed -n '2p' "$WORK/card-event")" in
        enable:failed) headline=启用失败 ;;
        disable:failed) headline=恢复失败 ;;
        refresh:failed) headline=刷新失败 ;;
    esac
fi
[ "$driver" = 匹配 ] || headline=驱动不匹配
[ "$driver" != 不可读 ] || headline=驱动不可读
[ "$kernel" = 匹配 ] || headline=内核不匹配
[ "$COMPAT_ERROR" != compatibility_table_invalid ] || headline=兼容表无效
if [ -e "$MODULE_OWNER/disable" ] || [ -L "$MODULE_OWNER/disable" ]; then headline=模块已禁用; fi
if [ -e "$MODULE_OWNER/remove" ] || [ -L "$MODULE_OWNER/remove" ]; then headline=模块待移除; fi

# Restrict the observation to a managed interface and its own PHY. Never
# mistake an unrelated USB adapter's 6GHz channels for the MT6639 radio.
six=未知
link=未知
if command -v iw >/dev/null 2>&1; then
    devices=$(timeout 2 iw dev 7>&- 2>/dev/null)
    if [ "$?" = 0 ]; then
        iface=$(printf '%s\n' "$devices" | awk '
            $1 == "Interface" { name=$2 }
            $1 == "type" && $2 == "managed" && name == "wlan0" { print name; exit }')
        if [ "$iface" = wlan0 ]; then
            info=$(timeout 2 iw dev "$iface" info 7>&- 2>/dev/null)
            if [ "$?" = 0 ]; then
                phy=$(printf '%s\n' "$info" | awk '$1 == "wiphy" { print $2; exit }')
                case "$phy" in
                    ''|*[!0-9]*) ;;
                    *)
                        channels=$(timeout 2 iw phy "phy$phy" info 7>&- 2>/dev/null)
                        if [ "$?" = 0 ] && printf '%s\n' "$channels" | grep -q 'MHz'; then
                            count=$(printf '%s\n' "$channels" | awk '
                                $1 == "*" && $3 == "MHz" && $2 >= 5925 && $2 <= 7125 &&
                                $0 !~ /\(disabled\)/ { n++ }
                                END { print n+0 }')
                            six="${count}个已注册信道"
                        fi
                        ;;
                esac
            fi
            association=$(timeout 2 iw dev "$iface" link 7>&- 2>/dev/null)
            if [ "$?" = 0 ]; then
                if printf '%s\n' "$association" | grep -q '^Not connected'; then
                    link=未连接
                elif printf '%s\n' "$association" | grep -q '^Connected to '; then
                    freq=$(printf '%s\n' "$association" | awk '
                        $1 == "freq:" && $2 ~ /^[0-9]+$/ && $2 >= 2400 && $2 <= 7125 { print $2; exit }')
                    [ -z "$freq" ] || link="${freq}MHz"
                fi
            fi
        fi
    fi
fi
stamp=$(date '+%H:%M:%S')
description="[$headline] 适配：$COMPAT_PROFILE | 内核：$kernel | 驱动：$driver | 配置：$cfg | 事务：$transaction | 6GHz：$six | 连接：$link | 更新：$stamp。信道注册不代表业务通过。"
if [ "$MODE" = show ]; then
    printf '%s\n' "$description"
    exit 0
fi

# Same-directory atomic replacement preserves complete metadata for readers.
# No arbitrary log text, SSID or BSSID enters the manager description.
tmp=$(mktemp "$MODDIR/.module.prop.XXXXXX") || exit 3
trap 'rm -f "$tmp"' EXIT
trap 'exit 143' HUP INT TERM
awk -v description="$description" '
    /^description=/ { print "description=" description; next } { print }
' "$TEMPLATE" >"$tmp" || exit 3
chmod 0644 "$tmp" || exit 3
mv -f "$tmp" "$MODDIR/module.prop" || exit 3
