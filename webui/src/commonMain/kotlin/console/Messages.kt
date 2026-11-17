package console

/**
 * Plain-language text for what the scripts report. The scripts speak in fixed
 * tokens; nothing here interprets free text.
 */
object Messages {
    fun phase(token: String): String = when (token) {
        "preflight" -> "检查运行条件"
        "six_enable" -> "启用 6GHz（WLAN 会重启一次）"
        "sta_settle" -> "等待 WLAN 恢复稳定"
        "hotspot_start" -> "启动热点"
        "verify" -> "确认热点已在运行"
        "six_rollback" -> "未能完成，正在归还 6GHz"
        "hotspot_stop" -> "停止热点"
        "six_restore" -> "恢复 6GHz 为原厂状态（WLAN 会重启一次）"
        "six_refresh" -> "重新注册 6GHz"
        "" -> "准备中"
        else -> token
    }

    fun opTitle(kind: OpKind): String = when (kind) {
        OpKind.Start -> "正在开启 6GHz 热点"
        OpKind.Stop -> "正在关闭热点"
        OpKind.SixOn -> "正在启用 6GHz"
        OpKind.SixOff -> "正在恢复 6GHz"
        OpKind.SixRefresh -> "正在重新注册 6GHz"
        OpKind.SetWidth -> "正在保存带宽"
        OpKind.SetKey -> "正在保存密码"
        OpKind.SetName -> "正在保存网络名称"
    }

    fun failureTitle(kind: OpKind): String = when (kind) {
        OpKind.Start -> "热点没有开启"
        OpKind.Stop -> "关闭没有完成"
        OpKind.SixOn -> "6GHz 没有启用"
        OpKind.SixOff -> "6GHz 没有恢复"
        OpKind.SixRefresh -> "重新注册没有完成"
        OpKind.SetWidth -> "带宽没有保存"
        OpKind.SetKey -> "密码没有保存"
        OpKind.SetName -> "网络名称没有保存"
    }

    /** Every reason this table knows. A repository test checks it against the scripts. */
    val KNOWN_REASONS: Set<String> get() = REASONS.keys

    /**
     * What happened and, where there is one, what to do about it. The runner's
     * own reason ([detail]) is more specific than the controller's, so it wins.
     */
    fun reason(reason: String, detail: String = "none"): String {
        val specific = detail.substringBefore(',').substringBefore('=')
        REASONS[specific]?.let { return fill(it, detail) }
        REASONS[reason]?.let { return fill(it, detail) }
        return "模块返回了未收录的原因：$reason。请查看下方的详细输出。"
    }

    private fun fill(text: String, detail: String): String {
        val freq = detail.split(',').firstOrNull { it.startsWith("sta_freq=") }
            ?.substringAfter('=')?.takeIf { it.isNotEmpty() && it != "none" && it.all(Char::isDigit) }
        return text.replace("{freq}", if (freq != null) "（当前 $freq MHz）" else "")
    }

    private const val NEED_WLAN = "WLAN 开关没有打开。请打开 WLAN（可以不连接任何网络），再试一次。"
    private const val NEED_6G_STA =
        "WLAN 现在连接在 2.4GHz 或 5GHz 网络{freq}。这颗芯片不能在这种连接旁边开 6GHz 热点。" +
            "请断开这个 WLAN 网络（保持 WLAN 开关打开）并打开移动数据，或者改连 6GHz 网络。"
    private const val NEED_CELL = "WLAN 未连接时热点用移动数据作上游，但现在没有可用的移动数据。请打开移动数据后再试。"
    private const val NOT_REVIEWED = "当前设备、系统、内核或 WLAN 驱动不在模块已核对的组合内，模块拒绝在未核对的组合上改动无线配置。"
    private const val RECOVER_HOTSPOT = "热点停在了未完成的状态。请点一次「关闭」，让模块按记录恢复，然后再开启。"
    private const val RECOVER_SIX = "6GHz 事务的状态不完整（事务还在，但看护进程不在或状态不是运行）。请先关闭 6GHz 开关让模块恢复，再重新开启。"

    private val REASONS: Map<String, String> = mapOf(
        // This controller.
        "radio_control_busy" to "另一个操作还在进行，请等它结束。",
        "hotspot_busy" to "热点模块正在执行别的操作（可能来自系统设置里的入口），请稍后再试。",
        "ap_key_missing" to "还没有设置热点密码。请先在「热点密码」里设置。",
        "enforcing_required" to "SELinux 不是 Enforcing。模块只在 Enforcing 下启动。",
        "android_env_unavailable" to "读不到 Android 运行环境（BOOTCLASSPATH），热点的框架调用无法执行。重启手机后再试。",
        "module_asset_hash_mismatch" to "模块文件与安装包里的校验值不一致。请重新安装本模块，不要在手机上修改模块文件。",
        "mtap0_exists" to "热点接口 mtap0 还留在系统里。请点一次「关闭」让模块清理。",
        "tethering_not_idle" to "系统自带的热点或其他网络共享正在使用。请先在系统设置里把它关掉。",
        "hotspot_status_unavailable" to "读不到热点模块的状态。",
        "hotspot_not_idle" to RECOVER_HOTSPOT,
        "hotspot_active_other_profile" to "热点已经在用另一种带宽或频段运行。请先关闭，再用新的带宽开启。",
        "hotspot_active" to "热点正在运行。这个操作会重启 WLAN，请先关闭热点。",
        "hotspot_not_active_after_start" to "启动命令返回了成功，但随后的检查没有确认热点在运行。模块已把它停掉。",
        "hotspot_not_confirmed_idle" to "停止命令返回了成功，但随后的检查没有确认热点已经空闲。",
        "hotspot_start_failed" to "热点模块没有启动成功，也没有给出具体原因。",
        "hotspot_stop_failed" to "热点模块没有停止成功，也没有给出具体原因。",
        "hotspot_module_disabled" to "本模块已在管理器里被禁用。",
        "hotspot_module_removing" to "本模块已被标记为待移除。",
        "hotspot_module_missing" to "找不到热点模块的控制脚本。请重新安装本模块。",
        "sixg_module_missing" to "内置 6GHz 后端缺失。请重新安装完整的二合一模块，不需要另装 6GHz 模块。",
        "legacy_six_module_present" to "检测到旧独立 6GHz 模块或待安装副本。请先停止热点、恢复 6GHz，在管理器卸载旧 mt6639-6g 并重启，再安装二合一包。",
        "unified_reboot_required" to "二合一模块刚安装，请完整重启手机后使用；软重启不算。",
        "unified_install_record_invalid" to "安装记录缺失或无效，请用管理器重新安装完整二合一包并重启。",
        "unified_module_directory_invalid" to "二合一模块目录无效，请重新安装。",
        "unified_boot_unreadable" to "读不到有效的内核启动标识，不能安全接管无线事务。",
        "unified_status_missing" to "后端未报告二合一就绪状态，请确认安装的是完整的新版本并重启。",
        "sixg_module_disabled" to "6GHz 模块（mt6639-6g）已在管理器里被禁用。",
        "sixg_module_removing" to "6GHz 模块（mt6639-6g）已被标记为待移除。",
        "sixg_status_unavailable" to "读不到 6GHz 模块的状态。",
        "sixg_needs_recovery" to RECOVER_SIX,
        "sixg_enable_failed" to "6GHz 模块没有启用成功，也没有给出具体原因。",
        "sixg_not_active_after_enable" to "启用命令返回了成功，但 6GHz 事务没有进入运行状态。模块已尝试把它恢复。",
        "sixg_restore_failed" to "6GHz 没有恢复成功。记录已保留，可以再点一次「关闭」接着完成。",
        "sixg_refresh_failed" to "重新注册没有成功，也没有给出具体原因。",
        "sta_status_unavailable" to "读不到 WLAN 状态（cmd wifi status 没有返回）。",
        "wifi_disabled" to NEED_WLAN,
        "session_record_unwritable" to "无法写入会话记录（/data/adb/mt6639-radio）。",
        "session_record_unremovable" to "无法清除会话记录（/data/adb/mt6639-radio）。",
        "width_unwritable" to "无法保存带宽设置（/data/adb/mt6639-radio）。",

        // Launch problems, from the exit status alone.
        "controller_missing" to "找不到控制脚本。请确认安装的是完整二合一模块（v0.4.0-dijun.1 或更新），并已重启。",
        "not_root_or_wrong_context" to "脚本没有运行在 KernelSU 的 root 环境（u:r:ksu:s0）里，或者工作目录的归属不对。",
        "module_files_missing" to "模块目录不完整。请重新安装本模块。",
        "work_directory_unwritable" to "无法准备工作目录 /data/adb/mt6639-radio。",
        "boot_id_unreadable" to "读不到本次开机的标识。",
        "usage_rejected" to "控制脚本不认识这条命令。控制台和脚本可能不是同一个版本，请重新安装本模块。",
        "no_result" to "操作结束了，但脚本没有给出结果。",
        "no_exit" to "等了很久也没有等到操作结束。状态已重新读取，请以页面显示为准。",

        // Network-name installer.
        "name_encoding_invalid" to "网络名称需要 1 到 32 个 UTF-8 字节，不能包含控制字符、换行或无效字符。",
        "name_directory_invalid" to "网络名称配置目录的归属或权限不正确。请重新安装本模块。",
        "name_file_invalid" to "网络名称配置文件不安全或无效。请重新安装本模块。",
        "name_unwritable" to "无法保存网络名称配置。",

        // Passphrase installer.
        "key_input_missing" to "脚本没有收到密码。",
        "key_encoding_invalid" to "密码在传给脚本时格式不对。",
        "key_length_invalid" to "密码需要 8 到 63 位。",
        "key_characters_invalid" to "密码只能包含英文字母、数字和常见符号。",
        "key_unwritable" to "无法写入密钥文件。",
        "key_not_installed" to "密钥文件写入后没有通过检查。",
        "private_directory_invalid" to "密钥目录 /data/adb/mt6639-hotspot/private 不是 root 的私有目录。",
        "work_directory_not_private" to "模块的工作目录不是 root 的私有目录。",

        // Hotspot controller and upstream resolver.
        "action_busy" to "热点模块正在执行别的操作，请稍后再试。",
        "sta_connection_incomplete" to "WLAN 正在连接中，还没有完成。请等几秒再试。",
        "upstream_connection_mismatch" to "模块配置的上游方式与当前的 WLAN 连接状态对不上。",
        "upstream_preflight_failed" to "上游网络的检查没有通过。",
        "wifi_disabled_driver_unavailable" to NEED_WLAN,
        "bad_upstream_mode" to "config.conf 里的上游方式不是模块认识的值。",
        "private_file_invalid" to "密钥文件不存在或权限不对。请在「热点密码」里重新设置。",
        "module_disabled_or_removing" to "模块已被禁用或标记为待移除。",
        "unsupported_band_width" to "模块不支持这个频段与带宽的组合。",
        "runner_exited_during_start" to "热点进程在启动过程中退出了。",
        "start_timeout" to "热点在限定时间内没有进入运行状态，模块已请求清理。请点一次「关闭」确认恢复。",
        "session_task_invalid" to "热点的会话记录无效，模块保留了现场。",
        "session_cross_boot" to "留有上一次开机的热点会话记录，模块不会在本次开机里处理它。",
        "runner_still_alive_after_cleanup" to "停止后热点进程仍在运行。",
        "guardian_still_alive_after_cleanup" to "停止后热点的看护进程仍在运行。",
        "interface_still_present" to "停止后热点接口 mtap0 仍然存在。",
        "tethering_still_active" to "停止后系统的网络共享仍然处于活动状态。",
        "recovery_rc" to "热点停止后的恢复检查没有通过。",
        "recovery_command_failed" to "热点的恢复命令没有成功。",
        "recovery_command_failed_retry" to "热点的恢复命令重试后仍没有成功。",
        "recovery_result_missing" to "热点的恢复没有留下结果。",
        "recovery_result_missing_retry" to "热点的恢复重试后仍没有留下结果。",
        "recovery_retries_exhausted" to "热点的恢复已经重试到上限。需要重启手机。",
        "recovery_cooldown" to "刚刚才尝试过恢复，请等二十秒再点。",
        "cleanup_request_failed" to "无法向热点进程发出清理请求。",
        "native_session_exists" to "已有一个热点会话。",
        "session_clear_failed" to "无法清除热点的会话记录。",

        // Hotspot runner.
        "sta_band_incompatible_with_6g" to NEED_6G_STA,
        "sta_connected_in_cell_mode" to "准备用移动数据作上游时，WLAN 又连上了一个网络。请断开或忘记那个网络后再试。",
        "cellular_data_unavailable" to NEED_CELL,
        "sta_frequency_unknown" to "读不到 WLAN 当前连接的频率。",
        "sta_upstream_mismatch" to "当前连接的 WLAN 与模块指定的实验上游不一致。",
        "missing_upstream_recovery_key" to "指定实验上游的恢复口令没有配置。",
        "hotspot_identity_rejected" to NOT_REVIEWED,
        "framework_ap_state_not_idle" to "系统的热点状态不是空闲。请先关闭系统自带的热点。",
        "framework_inspect_empty" to "读不到系统的热点状态。",
        "framework_inspect_failed" to "读取系统热点状态时出错。",
        "upstream_mode_unwritable" to "无法记录本次会话的上游方式。",
        "final_check_failed" to "热点启动后的最后一项检查没有通过。",
        "unreported" to "热点进程退出时没有留下原因。",

        // Reviewed identity.
        "device_mismatch" to NOT_REVIEWED,
        "sdk_mismatch" to NOT_REVIEWED,
        "kernel_mismatch" to NOT_REVIEWED,
        "driver_mismatch" to NOT_REVIEWED,
        "driver_unreadable" to "读不到 WLAN 驱动文件，无法核对它是不是已核对的版本。",
        "compatibility_table_invalid" to "模块内的兼容表损坏。请重新安装模块。",
        "identity_assets_missing" to "模块内缺少兼容表文件。请重新安装模块。",
        "identity_check_failed" to "设备与驱动组合的核对没有完成。",

        // 6GHz module.
        "wifi_must_be_enabled" to NEED_WLAN,
        "wlan_not_ready" to "WLAN 服务还没有就绪。请稍后再试。",
        "control_busy" to "6GHz 模块正在执行别的操作，请稍后再试。",
        "cfg_not_stock" to "WLAN 配置文件不是模块核对过的原厂版本，模块拒绝覆盖。",
        "ko_not_stock" to "WLAN 驱动不是模块核对过的版本，模块拒绝启用。",
        "cfg_already_mounted" to "WLAN 配置文件上已经有别的挂载，模块不会再叠加。",
        "module_control_not_ready" to "6GHz 模块的看护条件没有就绪。",
        "active_tx_invalid" to RECOVER_SIX,
        "active_pid_invalid" to RECOVER_SIX,
        "missing_or_cross_boot_authority" to "6GHz 事务的记录缺失或来自上一次开机。重启后模块会自行归档。",
        "native_missing" to "6GHz 模块缺少原生程序。请重新安装 6GHz 模块。",
        "state_not_active" to "6GHz 事务不在运行状态，没有可以重新注册的内容。请先启用 6GHz。",
        "guardian_not_alive" to RECOVER_SIX,
        "config_not_enabled" to "6GHz 模块的 config.conf 里把 ENABLE_6G 设成了 0，重新注册不会执行。",
        "module_disabled" to "6GHz 模块的 config.conf 里把 ENABLE_6G 设成了 0，重新注册不会执行。",
        "ksu_context_required" to "脚本没有运行在 KernelSU 的 root 环境（u:r:ksu:s0）里。",
        "country_baseline_unreadable" to "读不到 WLAN 的国家码状态。系统服务可能还在启动，请稍后再试。",
    )
}
