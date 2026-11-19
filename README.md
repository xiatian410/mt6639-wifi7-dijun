# MT6639 热点 + 6GHz 二合一源码分支

此分支 `ui-stability-20261119` 独立于 `main`，继承原二合一分支，基于已发布的 **v0.4.2-dijun.1**（`66c931138c13f2319a3d11f9ab6e93ab2d087291`），继续研究四页界面与功能稳定性。它保留完整仓库历史、构建依赖、测试、研究依据与许可证；其他历史研究目录仍保留，但不参与二合一 ZIP 的打包。本分支源码更新不代表已发布安装包更新。

## 二合一源码入口

| 内容 | 路径 |
| --- | --- |
| 唯一安装模块、热点控制与恢复 | [modules/mt6639-hotspot](modules/mt6639-hotspot/) |
| 内置 6GHz 后端共享源码 | [modules/mt6639-6g](modules/mt6639-6g/) |
| Android 原生恢复事务与 AP 停止屏障 | [native/recovery](native/recovery/) |
| Miuix Kotlin/Wasm WebUI | [webui](webui/) |
| hostapd、netdev、framework 等相关源码 | [native](native/) |
| 构建与运行脚本 | [tools](tools/) |
| 离线测试 | [tests](tests/) |

**安装仍只有一个 `mt6639-hotspot` 模块。** 构建器将共享 6GHz 后端嵌入 `six/`，不打包第二份模块元数据或生命周期入口。源码目录的拆分不意味着需要独立安装 6GHz 模块。

## 获取与构建

```sh
git clone --branch ui-stability-20261119 --single-branch \
  https://github.com/xiatian410/mt6639-wifi7-dijun.git
cd mt6639-wifi7-dijun
```

完整构建步骤、工具链要求和旧模块迁移见 [模块构建说明](modules/mt6639-hotspot/README.md#webui-构建与安装)。主要入口为 `tools/build_mount_txn.sh`、`tools/build_webui.sh` 和 `tools/build_hotspot_module.sh`。构建时将输出 ZIP 名称设为 `mt6639-hotspot-v0.4.2-dijun.1.zip`。

本分支包含项目源码，不包含预编译原生程序、DEX、ZIP、原厂驱动或固件。构建仍需要文档指定的 NDK、JDK、Gradle、字体、外部依赖与固定哈希的热点构建输入；不是无需依赖即可离线编译的 SDK。源码 ZIP 也不能直接作为 KernelSU 模块安装。

- [完整可安装 v0.4.2 ZIP](https://github.com/xiatian410/mt6639-wifi7-dijun/releases/download/v0.4.2-dijun.1/mt6639-hotspot-v0.4.2-dijun.1.zip)
- [本分支源码 ZIP](https://github.com/xiatian410/mt6639-wifi7-dijun/archive/refs/heads/ui-stability-20261119.zip)
- 原作者署名与 [GPL-3.0 许可证](LICENSE) 保留；第三方许可按各组件原文件。

离线夹具通过不代表 Android 真机无线或客户端联网验收。后续 `main` 的修改不会自动进入本分支，需要显式合并或挑选提交。

---

# 原研究仓库说明（历史内容）

## 本 fork 当前维护

2026-11-17：**6GHz + 热点二合一 v0.4.1-dijun.1** 补充持锁的跨启动热点会话退役：仅在确认旧启动且当前无活动残留时归档，失败保留证据；区分恢复后的联网等待失败与配置恢复。使用一个 ZIP、一个 `mt6639-hotspot` 模块 ID，内置 6GHz 后端和 Miuix WebUI，保留可编辑 SSID 与触摸滑动修复。原生事务程序已用 Android NDK 重编，恢复前先停热点并持操作锁完成恢复。**旧用户须先停止热点、恢复 6GHz，卸载旧独立 `mt6639-6g` 并完整重启，再安装二合一包并重启；新用户只安装二合一包。** 默认不开机自动启用无线。离线构建/夹具及浏览器验证不代表 Android 真机、无线或客户端联网验收。[构建、迁移与安装说明](modules/mt6639-hotspot/README.md)。

本批新增 **蓝牙 v0.2.0-dijun.1** 的 OS4 已核对组件适配、恢复重试与状态查询修复，以及 **热点 v0.2.23-dijun.1** 的直接入口目录验证。蓝牙不再因 OTA 显示版本变化而单独拒绝相同组件；未知 APK 仍拒绝启用。[本批范围、六模块状态与剩余边界](docs/研究-蓝牙组件与模块维护-20261115.md)。 [本批候选下载](https://github.com/xiatian410/mt6639-wifi7-dijun/releases/tag/v0.4.0-dijun.1)。

本仓库由 `xiatian410` 维护，继承 [Hi-Jiajun 的上游研究](https://github.com/Hi-Jiajun/mt6639-wifi7-dijun)。上游历史实机结论保留各自版本与前提。

2026-11-15：6GHz 模块更新为 **v0.3.3-dijun.1**，修复工作目录权限导致原生事务初始化返回 `64`。设备证据显示模块自己的工作目录为 `0777`，被原生祖先目录检查拒绝；共享入口现在先核对所有者、将该目录设为并验证为 `0700`，之后才写入日志/锁/状态。原生目录限制不放宽，已有记录不删除。更新后重启，由既有跨启动原厂状态检查归档旧记录。

保留 v0.3.2 对用户 WLAN 驱动 `1f962c07…771ac96` 的适配，以及原有驱动组合；同内核下的已核对变体共用精确身份、备份与恢复检查，不按系统显示版本设门槛。

保留上批动态状态卡：显示适配组合、内核/驱动匹配、配置状态、事务、6GHz 已注册信道数与当前连接频率。启动、操作完成和现有看护的每分钟周期更新；管理器可能需要刷新列表。版本/ID/静态脚本仍接受完整性校验。

**本版是离线适配候选，实际无线行为待设备确认。** 新版支持有固定内核、原厂驱动和配置哈希边界，不是忽略所有版本检查；未知组件会明确拒绝。相关驱动函数比较、构建和验证见 [新版兼容与状态卡说明](docs/研究-OS4新版兼容与模块状态卡-20261115.md)。

下载：[本 fork v0.3.3-dijun.1 适配候选](https://github.com/xiatian410/mt6639-wifi7-dijun/releases/tag/v0.3.3-dijun.1)。

下文 Release 表格对应**上游预发布构件**，不代表本 fork 已发布这些附件。

> **English abstract.** An open research archive of the MediaTek MT6639 Wi‑Fi/Bluetooth stack on
> Xiaomi 15S Pro (codename *Dijun*): what the vendor firmware actually gates, which configurations
> can be reproduced on real hardware, and where the limits are. It ships read‑only inspection and
> evidence tooling, host‑side offline tests, native fixtures, and the source of six KernelSU/LSPosed
> helper modules. It is **not** a one‑click unlock: the project records both successful experiments
> and the checks that still fail. See [DISCLAIMER.md](DISCLAIMER.md) for the compliance boundary.

这是一个**实验研究档案**，不是"全功能解锁完成"的日用发行版。它记录 MT6639 在 Xiaomi 15S Pro 上的能力边界：哪些 6GHz / Wi‑Fi 7 / EHT / 热点 / 蓝牙特性在特定固件版本和特定 AP 条件下真的跑通过，哪些只是属性声明，哪些被门禁或生命周期问题挡住。

历史上已在特定版本、独立 6GHz 网络中取得 6GHz / 320MHz EHT 双端关联和 ICMP 证据；重复回包、吞吐、恢复机制与长期稳定性尚未全部验收。属性或 PHY 速率不代表真实业务通过。

## 项目边界

- `dijun-oneclick` 之类的外部 root / KernelSU 工具不是本项目的一部分；本项目只消费已经可用的 root 权限，不改提权链，不改 BL。
- 不打包 root 利用链、原厂驱动/固件/NVRAM、校准数据、AP/手机凭据或第三方未经许可的 APK 与脚本。
- 不提供"功能最全国家码"默认值，不无条件修改功率或校准。国家码、信道与功率是分离的条件。
- 二进制构件（模块 ZIP、APK、以及其中第三方构建的 `hostapd`）只在 GitHub Release 发布，不进仓库树；仓库只保留可复现源码与构建脚本。

## 仓库内容

| 目录 | 内容 |
| --- | --- |
| `tools/` | 只读巡检、DUP/OFDMA/打孔取证、F01–F10 矩阵运行器、发布审计；依赖 Python 3 标准库 |
| `tests/` | 主机侧离线测试（480 项，按环境跳过缺失依赖的项目），含 C 夹具、Java LSPosed 夹具与 shell 契约测试 |
| `native/` | 原生夹具源码：恢复事务、netdev、mlo-gate、hostapd、TWT 桥 |
| `modules/` | 6 个 KernelSU / LSPosed 模块源码与可复现构建脚本 |
| `docs/` | 精选研究记录 41 篇：能力台账、门禁分析、逐项验证与部署/构建说明 |
| `release/` | 候选构件清单与校验值；构件本体在 [Releases](../../releases) |

## 快速开始

```sh
# 主机侧离线测试（不需要真机）
python3 -m unittest discover -s tests -v

# 包解析器自测
python3 tools/summarize_icmp_pcap.py --self-test

# 只读巡检：--out 必须是尚不存在的新目录，ADB 路径必须是绝对路径
python3 tools/inspect_mt6639.py --adb /absolute/path/to/adb \
  --serial YOUR_SERIAL --out /tmp/NEW_INSPECTION
```

测试会按环境自动 `skip`：缺少 `aapt2` / `javac` / Android SDK `android.jar`，或缺少本地已构建的模块构件时，对应用例会带原因跳过，不会伪装成通过。CI（`.github/workflows/ci.yml`）会尽量补齐 Android 工具链后再跑一轮。

巡检工具不扫描、不切网、不改国家码、不挂载或加载驱动；每次调用有超时，失败/空输出保留具体状态。原始输出可能包含网络身份，摘要只保留派生信息。工具退出 0 表示完成采集/解析，不表示所有探针成功、6GHz 可用或恢复通过。

## 研究结论入口

- [能力台账](docs/mt6639-plan/能力台账.md)：逐项登记已实现 / 已最小验证 / 已完整验收，以及未晋级原因。
- [范围-手机终端适用](docs/mt6639-plan/范围-手机终端适用-20261028.md)：适配范围与用例基线。
- [6GHz 门禁与生命周期](docs/分析-MT6639六GHz门禁与生命周期-20261022.md)、[全部监管表](docs/分析-MT6639全部监管表-20261022.md)、[信道禁用路径](docs/分析-MT6639信道禁用路径-20261022.md)。
- [国家码来源与 force-country-code 生命周期](docs/研究-国家码来源与force-country-code生命周期-20261027.md)。
- [原生 EHT 热点与共享接线](docs/部署-MT6639-UI-LSPosed-20261023.md)、[热点模块生命周期与可复现构建](docs/验证-热点模块生命周期与构建-20261025.md)。
- [DUP 三点取证](docs/分析-DUP三点取证方案-20261028.md)、[F04 正式测试流程](docs/分析-F04正式测试流程-20261028.md)、[打孔 ABC 三段](docs/验证-打孔ABC三段-20261028.md)。
- [恢复判定器 T02A](docs/mt6639-plan/T02A-恢复判定器-20261023.md)、[T02B 进程与 WAL 骨架](docs/mt6639-plan/T02B-进程与WAL骨架-20261023.md)。

完整目录见 [docs/README.md](docs/README.md)。

## 数据脱敏约定

研究记录中的设备标识已统一替换，复现时请使用你自己的实验环境值：

- 手机序列号 → `<PHONE_SERIAL>`，个人目录 → `<HOME>`；会话 UUID → `<UUID>`。
- MAC / BSSID → `02:00:00:*` 文档地址（保留后两字节以便区分不同节点），IPv4 → `198.51.100.0/24`、`203.0.113.0/24`（RFC 5737 文档用途网段）。
- 实验 AP 的 SSID 统一改为 `LabNet-*` / `LabMLO`。
- Java 包名 `com.hiliang.*` 是模块作者的代码命名空间，与位置信息无关。

## Release 构件

[上游 `v0.1.0-pre`](https://github.com/Hi-Jiajun/mt6639-wifi7-dijun/releases/tag/v0.1.0-pre) 附五个历史候选（非稳定版，未完成全部验收）：

| 构件 | 版本 | SHA-256（同时见 `release/SHA256SUMS`） |
| --- | --- | --- |
| `mt6639-6g-v0.2.16.zip` | 6G 模块 | `3a607543f3d455f212ff5d2a7423a16b6dee1edd338b3231bbda7935b1084430` |
| `mt6639-hotspot-v0.2.22.zip` | 热点模块 | `f38c8aba8ac57acdb7a9a06a1531eb7f277151a87a315318e33bad50a8abf9f8` |
| `mt6639-bt-v0.1.2.zip` | 蓝牙模块 | `c17f8e5a276d89c76901fc0596a0722480a502748f27e55febe513e0732efa89` |
| `mt6639-ui-lsposed-0.2.7.apk` | UI 徽标 | `8d8f03fe49f1565e6c99fe217b420ed570d47ca9b04b5a310cabf9eb1c2922e3` |
| `mt6639-aware-service-0.1.3.apk` | Aware 服务 | `42a75c62aa4dc00f310611eac74ccc7addf2e6ece4782287cf3c66fe410e86e7` |

这些是候选，不是"全功能可用"承诺：6G 模块在 Enforcing 生命周期、冷启动、长稳上仍有未完成项；热点模块默认关闭；Aware / 并发门禁只用于有界实验，不要在实验范围外启用。

## 许可证

本仓库自有代码与文档以 **GPL-3.0** 发布，全文见 [LICENSE](LICENSE)。Release 中的构件包含第三方组件（例如 BSD 许可的 `hostapd`），这些组件不因本仓库的 GPL 授权而改变许可；分发或再分发前请自行核对各组件的许可条款。商标、固件与驱动归属各自权利人。

## 贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。提交前请确认没有真实设备标识、凭据、原厂固件或未授权第三方二进制。
