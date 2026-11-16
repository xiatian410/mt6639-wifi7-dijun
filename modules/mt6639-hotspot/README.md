# MT6639 Native EHT Hotspot

当前源码版本为 **v0.3.0-dijun.1 / code35**：新增 6GHz 与热点的合并控制入口，「操作」按钮改为一键开启/关闭两层（见下节）；热点自身的启动、停止与恢复逻辑没有改动。以下为 v0.2.26-dijun.1 / code34 的说明，仍然适用。原生热点不再按旧 OTA fingerprint 拒绝已核对内核/驱动；蜂窝和普通 Wi-Fi 上游不再强制提供实验网络恢复口令。修复 v0.2.24 安装后完整性检查拒绝：KernelSU 在安装结束时删除 `customize.sh`，它不应出现在运行时的 `SHA256SUMS` 中。其余静态脚本、原生程序、DEX 和元数据模板仍校验；动态描述更新方式不变。请安装新构建包，不要在设备上重生成校验清单或绕过校验。本次未验证实机热点启动或客户端联网。

## 合并控制：6GHz + 热点（v0.3.0-dijun.1）

`bin/radio-control.sh` 把「启用 6GHz」和「启动 6GHz 热点」合成一个入口，模块的「操作」按钮与 WebUI 控制台都走它。它自己不改无线状态：每一步仍然调用 `mt6639-6g` 与本模块各自的 `control.sh`，两边原有的锁、校验、恢复逻辑照旧是最终裁决；它只负责排序、在已知必然失败时提前拒绝，以及把自己启用的 6GHz 还回去。

两个模块仍是各自独立的模块 ID。6GHz 的原生事务程序把 `/data/adb/modules/mt6639-6g` 和 `/data/adb/mt6639-6g` 写在已固定哈希的二进制里，不重新编译并实机验证就不能并成一个 ID。本批只改热点模块；`mt6639-6g` v0.3.3-dijun.1 不需要更新。

```sh
C="sh /data/adb/modules/mt6639-hotspot/bin/radio-control.sh /data/adb/modules/mt6639-hotspot"
$C status            # 轻量状态：6GHz 事务、热点快照、Wi-Fi/上游、密钥是否就绪
$C status full       # 另外执行受控的热点状态检查、完整性与身份核对、刷新 6GHz 状态卡
$C start [20|40|80|160|320]   # 一键开启；省略带宽时用 set-width 保存的值
$C stop              # 一键关闭
$C toggle            # 「操作」按钮：空闲时开启，否则关闭/恢复
$C six-on | six-off | six-refresh    # 单独的 6GHz 开关与重新注册
$C set-width 160     # 保存默认带宽
$C logs              # 合并控制、热点、6GHz 三份日志的末尾
echo "$HEX" | sh /data/adb/modules/mt6639-hotspot/bin/radio-key.sh /data/adb/modules/mt6639-hotspot set
```

**一键开启的顺序。** ①只读预检；② 6GHz 事务未运行时调用 `mt6639-6g` 的 `enable`；③启用会重启 Wi-Fi，等待 STA 状态连续三次采样一致后重做上游预检；④ `control.sh start 6g 带宽`；⑤用受控状态检查和公开快照确认 `active / 6g / 带宽`，不一致就停止热点。任何一步失败，如果 6GHz 是本次启用的，就调用 `disable` 还回去；原本就在运行的 6GHz 不动。

**提前拒绝（不产生任何无线变更）。** 模块缺失/禁用/待移除、非 Enforcing、`ap.key` 缺失或权限不对、完整性校验失败、设备/SDK/内核/驱动不在已核对组合内、系统共享正在使用、`mtap0` 已存在、热点不是空闲、6GHz 事务需要先恢复、Wi-Fi 关闭、STA 连接在 2.4/5GHz（本驱动会把 6GHz AP 挪到 STA 信道，runner 本来也拒绝）、蜂窝模式下 10 秒内没有蜂窝 IPv4 地址。这些都是热点或 6GHz 控制器自己的门槛，放到前面只是避免「先重启一次 Wi-Fi 启用 6GHz、再失败、再重启一次还回去」。

**归还规则。** 只有本控制器启用的那个 6GHz 事务才会在「一键关闭」时恢复。记录在 `/data/adb/mt6639-radio/session`（root、0600），包含 boot ID 与事务路径；只有 boot 相同且当前事务路径与记录一致才执行恢复。上一次启动留下的记录直接丢弃，格式不对的记录改名为 `session.invalid.*` 保留，两者都不会被用来关闭 6GHz。用户自己用 6GHz 开关启用的事务不记为归属，关闭热点后保持开启。恢复失败时记录保留，再次「关闭」可以接着完成。

**单独的 6GHz 开关。** `six-off` 与 `six-refresh` 会重启 Wi-Fi，所以要求热点空闲，否则返回 `hotspot_active`。

**锁。** `/data/adb/mt6639-radio/control.lock` 只串行化本控制器的操作；所有子进程都以 `8>&-` 启动。6GHz 看护进程与热点 runner 比脚本活得久且不会关闭继承的描述符，继承到锁就会一直占着。受控的热点状态检查沿用 `status-card.sh poll` 的协议：先拿 `action.lock`，热点操作进行中就跳过，只读快照。

**输出。** 操作过程逐行输出 `phase=<步骤>`，结束时输出一行 `result=ok` 或 `result=failed step=… reason=… detail=… rc=…`；`reason` 取自底层控制器最后一条 `REJECT`。退出码沿用现有约定：64 用法、66 缺输入、69 不可用、73 状态冲突、74 I/O、75 忙、77 权限。`status` 的 `six_card=` 是 6GHz 模块自己渲染的状态卡文本；状态输出只包含上游模式与 STA 频率，不含 SSID、BSSID 或口令。

**热点密码。** `radio-key.sh set` 从标准输入读一行小写十六进制（口令各字节），解码后按 `softap_native_config.sh` 的同一条件校验（单行、8–63 个可打印 ASCII），以 0600 原子写入 `private/ap.key`。口令不出现在任何命令行参数、日志或输出里；`status` 只回答有没有可用的密钥文件。

**验证范围。** `tests/test_radio_control.py`、`tests/test_radio_key.py` 用两个模块控制器的替身覆盖排序、提前拒绝、回滚、归属和锁，并直接运行真实的热点 `control.sh status`、`status_snapshot.sh` 与 6GHz `control.sh status` 核对字段；在 dash、mksh R59、busybox ash 以及 gawk、mawk、busybox awk 下通过。没有在手机上运行，未验证真实的 6GHz 启用、热点启动或客户端联网。

这是显式操作型实验模块，默认关闭。KernelSU 的“操作”按钮在空闲时启动独立 6GHz EHT 热点，在已有会话时执行 checked stop。源码候选已通过独立的 Settings 请求桥接线，提供受 readiness 门禁保护的频段/带宽选择、启动与停止；不接管原厂热点总开关。下文 v0.2.9/code17、UI v0.2.6/code12 及部署状态为历史记录，不代表当前候选。历史固定哈希及安装前提见[交付手册](../../docs/交付-MT6639候选安装与回滚-20261026.md)。已冻结的历史ZIP字节保持不变，本文的后续说明不代表包内历史README已更新。

## 安装前

模块 ZIP 由 `tools/build_hotspot_module.sh` 从已验证候选构建，不能直接拿源码目录当可运行模块。构建器固定本机 hostapd、hostapd_cli、NativeTether DEX、按 ifindex 删除 helper 与 SoftAP profile DEX 的哈希，并排除 `local/`、`outputs/`、日志和密钥。

私有文件放在 `/data/adb/mt6639-hotspot/private/`，目录 0700、文件 0600、root所属：

- `ap.key`：独立热点口令，单行 8–63 个可打印 ASCII 字符。
- `reconnect.key`：仅指定实验网络 `wifi` 模式的 6GHz AP profile 需要，用于 LabNet-6G 上游验证/恢复；蜂窝 `cell` 和普通 Wi-Fi `wifi-any` 模式不需要。
- `reconnect-2g.key`：指定实验网络 `wifi` 模式的 2.4/5GHz 原生 AP profile 使用；`cell`、`wifi-any` 不需要。C02 一次性 framework 实验是独立入口，仍保留其原有条件。

模块包和 Git 仓库都不包含这些密钥文件。`ap.key` 始终必需，上游恢复口令按本次解析的模式检查；状态快照只公开
对应布尔 readiness，不公开口令内容。

## 前置条件

- 原生热点：Dijun、SDK 37、已审查的内核/原厂 WLAN 驱动组合与模块完整性通过。不按系统显示版本放行或拒绝；组件未知时仍拒绝。共享服务 JAR 和原生构件继续按原哈希核对。
- SELinux Enforcing；Permissive 下拒绝启动，避免把宽容窗口当成产品状态。
- KernelSU action 在 root/`u:r:ksu:s0` 执行。
- `mt6639-6g` 事务正常，`mt6639-hotspot` 不在 `disable/remove` 状态。
- 默认 `MT6639_HOTSPOT_UPSTREAM=auto`：Wi-Fi 开启但未连接网络时选择 `cell`（需移动数据）；连接指定实验网络时选择 `wifi`；其他已连接网络选择 `wifi-any`。控制器解析一次，runner 启动前重查并沿用所选模式，所选模式与当前连接状态不再相符时会拒绝。
- `cell`、`wifi-any` 仅需 `ap.key`。原有频段并发限制继续保留：例如 6GHz AP 不接受 2.4/5GHz STA 上游；Wi-Fi 关闭时驱动不可用，不能启动蜂窝共享热点。
- 指定实验网络 `wifi` 模式保留原 SSID/频率/BSSID 及恢复口令检查；不要用假口令填补文件。旧 C02 framework 入口尚未纳入新版内核/驱动适配。

## 状态

工作目录为 `/data/adb/mt6639-hotspot`。每轮任务保存在 `/data/local/tmp/mt6639-native-ap-*`，停止后保留供审计。控制器会核对 runner PID、boot、配置状态、系统 Tethering 状态、`mtap0` 和恢复结果；单独出现 `TetheredState` 或 hostapd `ENABLED` 都不算完整成功。

当前仍保留同步审查待办中的异常恢复边界。异常终止、接口消失和跨 boot 争议状态必须 fail-closed，不应用“进程不在”清除 authority。系统热点 UI、IPv6/offload、客户端业务、宽带宽及长期稳定验收归 F07/F10。

模块会把 `idle/starting/active/stopping/unresolved/disabled`、频段、带宽和当前 boot ID 原子写入公开只读快照 `/data/misc/mt6639-hotspot/status`。该文件不含口令、SSID、PID、任务路径或命令，只供 LSPosed Settings 模块展示。开机 `service.sh` 在自动启动关闭时也会写入当前 boot 的 `idle/disabled` 初始状态，跨 boot 的旧快照会被 UI 判定为过期。

Settings 启动/停止使用其 app-private 目录 `/data/user/0/com.android.settings/files/mt6639-hotspot`，目录必须为 `system:system 0700`、label `system_app_data_file`。这里的 `1000` 是 `android.uid.system` shared UID，不是 Settings 包独占来源证明。Settings 只能提交 `schema=mt6639-hotspot-request-v1` 的固定请求；`request_worker.sh` 在 KSU 域把文件原子移入 root-private claim 目录，并校验 owner/gid/0600、boot、60 秒有效期和一次性 32 位 nonce。只支持 `start 6g/20/40/80/160/320`、`start 5g/20/40/80` 固定白名单与 `stop`，不解析任意命令、频段、宽度、路径或 shell 片段。5GHz 只有在当前真实上游为 LabNet-2.4G/2412MHz/指定 BSSID 时才在 UI 开放。非法队首文件会移入 root-private quarantine，不会阻塞后续合法 stop。请求结果写入 root-private 审计日志，实际状态仍只由现有 snapshot 与控制器的 checked terminal state 决定。

历史实现 v0.2.4（2026-10-26）整合了 5GHz/2.4GHz-STA 上游 profile、2.4GHz HE/非EHT SoftAP profile、分资源恢复和 `control.sh ... c02-24g` 一次性验收入口。C02 入口要求 Enforcing/KSU、模块 SHA、`reconnect.key` 私有权限、无 native session、无 `mtap0`、Tethering idle，再把固定的 framework profile runner 放进新任务目录；成功必须同时满足 2.4GHz/11ax BSS、action rc0 和 recovery rc0。它仍是同步一次性测试，不会伪装成持久 2.4GHz 热点。停止共享改为调用 `stopTetheringRequest` 并按 type/interface 请求匹配；Android 服务实现最终仍按 type 清理，因此同 type 请求并发仍需真机验证。恢复每次使用新的 root 私有 STA 检查目录，避免重复运行把已存在的验证目录误判为失败并触发重选。hostapd 需通过可执行文件路径与任务私有 `ap.conf` 匹配，并在能读到 starttime 时同时核验。只有 radio、Tethering、ApEHT 与监管域均安全时才允许 STA 重选。

历史实现 v0.2.5 / versionCode 13（2026-10-26）增加启动暂存事务的 fail-closed 清理。任务目录在 session 发布前如果复制、密钥落盘、权限设置、profile render/check 或 session 文件写入失败，控制器只删除本任务已知文件；存在未知文件、guardian/native PID 指纹或 session 仍引用该目录时拒绝递归清理并保留现场。该路径避免失败时遗留热点/上游 Wi-Fi 口令。

历史实现 v0.2.6 / versionCode 14（2026-10-26）增加 Settings 请求 worker 的 claimed 恢复。worker 在执行 `control.sh` 前为 claimed 请求写入 `.execute` intent；若进程在执行中死亡，下一次 worker 启动会把残留请求移入 rejected 并记录
`result=interrupted_claim`、`rc=255`，不会自动重放可能已执行的 start/C02。无 `.execute` 的残留同样保守隔离并保留文件。

netdev 删除改用静态 AArch64 helper 对保存的 ifindex 发 `NL80211_CMD_DEL_INTERFACE`，由 cfg80211/驱动正式销毁无线虚拟接口，不在最后一步按名称重新查找。helper 来源为 `native/netdev/delete_ifindex.c`，通过 netlink ACK 验证请求接受或目标 ifindex 已不存在；真机 SELinux、内核响应及错误路径仍需后续验证。

v0.2.6 是历史离线候选，当前候选为v0.2.9/code17；后续补齐了session归属、worker独占与首次安装WORK初始化。只通过 shell 语法、静态边界检查、暂存清理/claim 恢复故障夹具、打包检查和宿主恢复测试，未在 Android、SELinux Enforcing 或真实故障注入场景运行。5GHz profile 尚未真机验证，且当前缺少独立的 `reconnect-2g.key`；2.4GHz SoftAP 也尚未真机启动。手机已安装的是 v0.1.6，新候选仍未安装，因此不能宣称异常生命周期、5GHz EHT 或 C02 已验收。

## 命令

```sh
sh bin/control.sh /data/adb/modules/mt6639-hotspot status
sh bin/control.sh /data/adb/modules/mt6639-hotspot start [6g 20|40|80|160|320 | 5g 20|40|80]
sh bin/control.sh /data/adb/modules/mt6639-hotspot stop
sh bin/control.sh /data/adb/modules/mt6639-hotspot recover
sh bin/control.sh /data/adb/modules/mt6639-hotspot toggle
sh bin/control.sh /data/adb/modules/mt6639-hotspot c02-24g
sh bin/status_snapshot.sh /data/adb/modules/mt6639-hotspot init
```


## 本 fork：直接控制入口的工作目录修复

v0.2.23-dijun.1 在 `control.sh` 写日志、锁或会话前检查工作目录：父目录和目录必须为 root 所有，拒绝符号链接及普通文件，目录创建/权限修改失败立即退出。已有 root 目录的权限会校正并回读为 `0700`。此前只有 worker 有类似检查，直接操作入口并未覆盖。

已离线执行真实控制脚本的初始化段，覆盖正常/缺失目录、旧宽松权限、符号链接、普通文件、错误所有者及 chmod 失败；没有运行热点、挂载或驱动操作。不据此增加新版 Android 框架、hostapd 或客户端兼容声明。

## 动态模块状态卡（v0.2.24-dijun.1）

KernelSU 模块列表的描述现在显示当前数据，例如：

```text
[热点运行] 频段：6GHz | 配置带宽：20MHz | 热点密钥：已配置 | 恢复配置：6G有/2G缺失 | SELinux：Enforcing | 恢复：未记录 | 最近操作：启动成功 | 更新：12:34:56。状态检查不代表客户端联网。
```

这是格式示例，不是本次实机结果。带宽是热点配置值，不是客户端协商速率。密钥栏仅显示文件是否满足既有权限条件，不读取或展示密码；不展示 SSID、MAC、配对信息、启动标识或私有目录。

- 启动时和每次状态快照发布后更新；启动/停止/恢复等操作结束时记录其真实返回码并刷新。
- 默认 Settings 请求 worker 约每 30 秒执行一次既有只读状态检查；没有新增常驻进程。检查通过后才沿用控制器的运行态判定，不启动热点、不切网、不执行恢复。
- 操作正在进行时跳过周期检查，以免与启动/停止争抢；状态快照仍可展示启动中/停止中。禁用或待移除时，worker 退出前更新相应描述。
- 旧 boot、超过 90 秒的快照、损坏或查询失败都会明确显示。禁用 `ENABLE_SETTINGS_BRIDGE` 后没有周期刷新，启动/手动操作仍更新；可显式调用下面的只读检查。
- KernelSU 管理器可能缓存模块描述，返回列表或重新打开管理器后显示最新内容。不是管理器内的实时动画组件。

```sh
# 显示现有快照，不发布 module.prop
sh /data/adb/modules/mt6639-hotspot/bin/status-card.sh /data/adb/modules/mt6639-hotspot show
# 执行一次既有只读状态检查并刷新描述
sh /data/adb/modules/mt6639-hotspot/bin/status-card.sh /data/adb/modules/mt6639-hotspot poll
```

以上命令在设备 root / KernelSU 环境运行。本仓库维护过程仅做离线测试。

构建时保存 `module.prop.template` 并纳入静态校验。运行时只替换 `description`，版本、ID 和脚本等仍校验，`SHA256SUMS` 不随展示更新。`config.conf` 保留既有可配置方式。显示失败不会改写热点操作返回码，也不会触发无线动作。
