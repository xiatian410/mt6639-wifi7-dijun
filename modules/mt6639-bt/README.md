# MT6639 LE Audio Host profile 模块

适用于 Xiaomi 15S Pro（Dijun）、Android 17 / SDK 37，由 KernelSU 管理 root 和模块。独立于 6GHz 模块。v0.2.0-dijun.1 按活动 Bluetooth APK 校验，支持已核对的 OS4 初始版与 OS4.0.4 正式版组件；不再绑定整个 OTA 的 fingerprint 或 APEX 应用目录中的构建编号。

已核对 APK SHA-256：

- 初始版：`22f2e2ac8c036f7716e792f1fa54d7f5c3dd53754cb3c01db93ee3981cd34339`。
- OS4.0.4：`1a5ae65ccd8621c03ca5a6a035979eac74025c3ecdda19dd84f1bbd53162983e`。

从活动 `/apex/com.android.bt/app/Bluetooth*/Bluetooth.apk` 唯一选择 APK；缺失、多个候选、读取失败或未知哈希会明确拒绝启用。OTA 版本变化但组件未变时可继续使用；新组件仍需核对，不承诺任意 OS4 更新。状态与恢复可在组件更新后运行，避免因启用门禁失去原值恢复路径。

默认开放本机已真实加载的六个 Host profile：BAP unicast client、broadcast source/assistant、CSIP coordinator、VCP controller、MCP server。它只开放 Host 入口，不伪造控制器能力、不强制 LC3，也不代表广播 sink、CIS/BIS、耳机互通或音频播放已验证。传统蓝牙、配对数据、offload 配置和 HAP 保持原路径。

## 安装与操作

通过 KernelSU 安装 ZIP。late-load 场景可在安装生效后显式运行本模块 service；模块不会自动重启手机或开关蓝牙。

```sh
su -c 'sh /data/adb/modules/mt6639-bt/service.sh'
su -c 'sh /data/adb/modules/mt6639-bt/bin/control.sh status'
su -c 'sh /data/adb/modules/mt6639-bt/bin/control.sh restore'
su -c 'sh /data/adb/modules/mt6639-bt/bin/control.sh enable'
```

KernelSU 操作按钮切换本 boot 的启用/恢复状态。`config.conf` 的 `ENABLE_LE_AUDIO=1` 为默认启用；设为0则下次 service 恢复原值。这六项是非持久属性。按标准 KernelSU 生命周期，禁用模块在下次 boot 生效；同 boot 立即撤销需调用 `restore`，卸载脚本也会请求恢复。

原值和 SHA256 保存在 `/data/adb/mt6639-bt/<boot-id>/`，不随模块目录移除；不重放其它 boot 的快照。避免与旧 `mt6639-full` 等模块同时修改这六个属性。

如果蓝牙已开启，属性变化与已加载的 profile 不一定同步，要等正常关闭/开启后采用新值；恢复同理，属性恢复不等于运行中的 profile 已卸载。模块不打断现有音频，也不自行重启蓝牙。

## 恢复与证据边界

使用标准属性服务 `setprop`，动作串行执行并逐项回读。失败时尝试恢复，恢复失败保留快照并发布 `restore_failed`；此时操作按钮会重试恢复，不会误切回启用。状态文件通过同目录临时文件替换发布；中断后可以显式恢复。它不是平台原子 CAS，避免外部并发编辑。快照损坏或冲突时拒绝覆盖，恢复态再次启用前核对基线。

历史旧版最小验证包含一次真实 Host 加载与属性/蓝牙生命周期恢复。外设音频角色及性能未验收；完整故障矩阵和生命周期后置 F01/F08。早期直接内存写属性版本虽能回读 true，但 Host 未加载；改用 setprop 后六个 profile 实际加载。两次结果独立保留，不以属性回显代替功能证据，也不将这一对照扩大为底层缓存机制已完全定位。


## 本 fork 的离线维护

- 新版七个 `isEnabled` 方法（六个角色加广播 Kotlin Companion）去除调试行后相同；`Config` 新增的厂商单播开关是与原入口的或关系。不是整套 APK 行为等价证明。
- 状态经带 5 秒超时的 shell 域查询蓝牙开关；服务错误、超时和异常输出显示 `unknown`，不会伪装为关闭。不会查询配对设备或设备地址。
- 工作目录核对 root 所有者并设为 `0700`，拒绝目录/锁/状态标记的符号链接；按当前 boot 保留快照。
- 16 项原控制入口离线测试覆盖新旧组件、失败恢复、幂等、混合原值、外部冲突、快照损坏、跨 boot 隔离和查询失败。Android 属性服务、SELinux、Binder 是夹具边界，当前手机的 APK 与音频行为仍未验证。

可复现构建（仅源码脚本，无原厂 APK 或固件）：

```sh
python3 tools/build_bt_module.py /absolute/path/to/NEW-mt6639-bt.zip
```

ZIP 内 `SHA256SUMS` 对应全部打包源码，脚本权限固定，时间戳归一化；不会覆盖已有输出。它是离线适配候选，不能称为蓝牙全部角色已可用。
