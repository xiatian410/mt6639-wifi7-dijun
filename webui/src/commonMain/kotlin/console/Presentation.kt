package console

/** One line of the "运行条件" list. [ok] is null while the value is not known. */
data class Condition(val title: String, val summary: String, val ok: Boolean?)

/** What the page shows and allows, derived from one state. No decisions live in the UI code. */
object Presentation {
    fun hotspotChecked(state: ConsoleState): Boolean {
        when (state.op?.kind) {
            OpKind.Start -> return true
            OpKind.Stop -> return false
            else -> {}
        }
        // A hotspot that is neither idle nor confirmed still needs a "关闭".
        return when (state.status?.hotspotState) {
            HotspotState.Active, HotspotState.Starting, HotspotState.Stopping,
            HotspotState.Unresolved -> true
            else -> false
        }
    }

    fun hotspotEnabled(state: ConsoleState): Boolean {
        val s = state.status ?: return false
        if (state.op != null || s.busy) return false
        return when (s.hotspotState) {
            HotspotState.Idle -> s.unifiedReady
            HotspotState.Active, HotspotState.Unresolved -> true
            else -> false
        }
    }

    fun hotspotSummary(state: ConsoleState): String {
        val op = state.op
        if (op != null && (op.kind == OpKind.Start || op.kind == OpKind.Stop)) {
            return Messages.opTitle(op.kind)
        }
        val s = state.status ?: return "状态未知"
        return when (s.hotspotState) {
            HotspotState.Active -> when {
                s.hotspotBand != "6g" -> "热点正在其他频段运行，不是由本页开启"
                s.hotspotChannel != null && s.hotspotFreq != null ->
                    "已开启 · ${s.shownWidth} MHz · 信道 ${s.hotspotChannel}（${s.hotspotFreq} MHz）"
                else -> "已开启 · ${s.shownWidth} MHz"
            }
            HotspotState.Idle -> if (!s.unifiedReady) Messages.reason(s.unifiedReason)
                else if (s.sixReady) "已关闭" else "已关闭 · 开启时会先启用 6GHz"
            HotspotState.Starting -> "正在启动（由其他入口发起）"
            HotspotState.Stopping -> "正在停止（由其他入口发起）"
            HotspotState.Unresolved -> "状态未确认 · 关闭开关可让模块恢复"
            HotspotState.Disabled -> "模块已禁用"
            HotspotState.Unknown -> "状态未知"
        }
    }

    /** Width can change only while nothing is running; a running hotspot keeps its width. */
    fun widthEnabled(state: ConsoleState): Boolean {
        val s = state.status ?: return false
        return state.op == null && !s.busy && s.hotspotState == HotspotState.Idle
    }

    fun nameEnabled(state: ConsoleState): Boolean = state.loaded && widthEnabled(state)

    fun nameSummary(state: ConsoleState): String {
        val name = state.status?.ssid ?: "状态未知"
        return if (state.op?.kind == OpKind.SetName) "$name · 正在保存名称" else
            "$name · 需先关闭热点再修改，下次开启生效"
    }

    fun keyEnabled(state: ConsoleState): Boolean = state.op == null && state.status != null

    fun keySummary(s: RadioStatus): String =
        if (s.apKey) "已设置 · 不会显示，可随时更换" else "未设置 · 开启热点前需要先设置"

    /** On also while a transaction needs recovery, so that switching off restores it. */
    fun sixChecked(state: ConsoleState): Boolean {
        when (state.op?.kind) {
            OpKind.SixOn -> return true
            OpKind.SixOff -> return false
            else -> {}
        }
        val s = state.status ?: return false
        return s.sixReady || s.sixTx == SixTx.Present || s.sixTx == SixTx.Invalid
    }

    fun sixEnabled(state: ConsoleState): Boolean {
        val s = state.status ?: return false
        if (state.op != null || s.busy || !s.unifiedReady) return false
        if (s.sixModule == ModuleState.Missing || s.sixModule == ModuleState.Unknown) return false
        // Enabling needs an enabled module; restoring does not.
        if (!sixChecked(state) && s.sixModule != ModuleState.Present) return false
        return s.hotspotState == HotspotState.Idle
    }

    fun sixSummary(state: ConsoleState): String {
        val op = state.op
        if (op != null && (op.kind == OpKind.SixOn || op.kind == OpKind.SixOff || op.kind == OpKind.SixRefresh)) {
            return Messages.opTitle(op.kind)
        }
        val s = state.status ?: return "状态未知"
        val base = when {
            s.sixModule == ModuleState.Missing -> return "内置 6GHz 后端缺失，请重新安装完整二合一模块"
            s.sixModule == ModuleState.Removing -> "6GHz 模块已标记为待移除"
            s.sixModule == ModuleState.Disabled && !s.sixReady -> "6GHz 模块已被禁用"
            s.sixReady && s.sessionOwns6g -> "已启用 · 由一键开启启用，关闭热点时一并恢复"
            s.sixReady -> "已启用"
            s.sixTx == SixTx.Present -> "事务状态不完整 · 关闭开关可让模块恢复"
            s.sixTx == SixTx.Invalid -> "事务记录无效 · 关闭开关可让模块恢复"
            s.sixTx == SixTx.None -> when (s.sixState) {
                "restore_failed" -> "未启用 · 上一次恢复没有成功"
                "recovery_blocked" -> "未启用 · 上一次恢复被阻止"
                else -> "未启用"
            }
            else -> "状态未知"
        }
        return if (s.hotspotState != HotspotState.Idle && s.hotspotState != HotspotState.Unknown &&
            s.hotspotState != HotspotState.Disabled
        ) {
            "$base · 热点运行期间不能切换"
        } else {
            base
        }
    }

    fun sixRefreshEnabled(state: ConsoleState): Boolean {
        val s = state.status ?: return false
        return state.op == null && !s.busy && s.unifiedReady && s.sixReady && s.sixModule == ModuleState.Present &&
            s.hotspotState == HotspotState.Idle
    }

    /** The checks a start runs first, in the order the script runs them. */
    fun conditions(s: RadioStatus): List<Condition> {
        val list = ArrayList<Condition>()
        list += Condition("二合一模块", if (s.unifiedReady) "已完成安装后的重启" else Messages.reason(s.unifiedReason), s.unifiedReady)
        list += when (s.sixModule) {
            ModuleState.Present -> Condition("6GHz 后端", "已内置 ${s.sixVersion}", true)
            ModuleState.Disabled -> Condition("6GHz 模块", "已在管理器里被禁用", false)
            ModuleState.Removing -> Condition("6GHz 模块", "已标记为待移除", false)
            ModuleState.Missing -> Condition("6GHz 后端", "内置文件缺失，请重装二合一模块", false)
            ModuleState.Unknown -> Condition("6GHz 模块", "状态未知", null)
        }
        list += when (s.identity) {
            true -> Condition("设备与驱动", "在已核对的组合内（${s.sixProfile}）", true)
            false -> Condition("设备与驱动", Messages.reason(s.identityReason), false)
            null -> Condition("设备与驱动", "等待检查", null)
        }
        list += if (s.enforcing) {
            Condition("SELinux", "Enforcing", true)
        } else {
            Condition("SELinux", "不是 Enforcing，模块不会启动", false)
        }
        list += if (s.apKey) {
            Condition("热点密码", "已设置", true)
        } else {
            Condition("热点密码", "未设置", false)
        }
        list += when (s.integrity) {
            true -> Condition("模块完整性", "校验通过", true)
            false -> Condition("模块完整性", "校验没有通过，请重新安装本模块", false)
            null -> Condition("模块完整性", "等待检查", null)
        }
        list += when (s.wifi) {
            true -> Condition(
                "WLAN",
                when (s.staConnected) {
                    true -> if (s.staFreq != null) "已打开 · 连接在 ${s.staFreq} MHz" else "已打开 · 已连接"
                    false -> "已打开 · 没有连接网络"
                    null -> "已打开"
                },
                true,
            )
            false -> Condition("WLAN", "没有打开。请打开 WLAN，可以不连接网络", false)
            null -> Condition("WLAN", "读不到状态", null)
        }
        // The station only decides whether a start is possible.
        if (!s.hotspotOn) {
            list += when (s.upstream) {
                "cell" -> when (s.cellData) {
                    true -> Condition("上游网络", "移动数据", true)
                    false -> Condition("上游网络", "WLAN 未连接，需要打开移动数据", false)
                    null -> Condition("上游网络", "移动数据（未检查）", null)
                }
                "wifi", "wifi-any" -> if (s.upstreamOk) {
                    Condition("上游网络", "当前的 6GHz WLAN 连接", true)
                } else {
                    Condition(
                        "上游网络",
                        "WLAN 连接在 2.4GHz 或 5GHz，不能与 6GHz 热点同时使用。请断开该网络并打开移动数据，或改连 6GHz 网络",
                        false,
                    )
                }
                "rejected" -> Condition("上游网络", Messages.reason(s.upstreamReason), false)
                else -> Condition("上游网络", "读不到状态", null)
            }
        }
        return list
    }

    /** How many conditions currently stand in the way of a start. */
    fun blocking(s: RadioStatus): Int = conditions(s).count { it.ok == false }

    /** The 6GHz module renders its card as one line; show one item per line. */
    fun cardText(card: String): String = card.replace(" | ", "\n")

    fun versions(s: RadioStatus): String =
        "二合一模块 ${s.hotspotVersion} · 内置 6GHz 后端 " +
            if (s.sixModule == ModuleState.Missing) "缺失" else s.sixVersion
}
