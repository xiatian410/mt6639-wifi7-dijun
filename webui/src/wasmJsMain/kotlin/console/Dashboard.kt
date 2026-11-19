package console

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.style.TextAlign
import top.yukonga.miuix.kmp.icon.MiuixIcons
import top.yukonga.miuix.kmp.icon.extended.Home
import top.yukonga.miuix.kmp.icon.extended.Settings
import top.yukonga.miuix.kmp.icon.extended.Search
import top.yukonga.miuix.kmp.icon.extended.Info
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import top.yukonga.miuix.kmp.basic.*
import top.yukonga.miuix.kmp.preference.ArrowPreference
import top.yukonga.miuix.kmp.theme.MiuixTheme

internal enum class ConsolePage(val label: String) {
    Home("首页"), Settings("配置"), Diagnostics("诊断"), About("关于")
}

@Composable
internal fun PageNavigation(selected: ConsolePage, onSelect: (ConsolePage) -> Unit) {
    Box(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 16.dp), contentAlignment = Alignment.Center) {
        BoxWithConstraints(Modifier.widthIn(max = 360.dp).fillMaxWidth()
            .shadow(12.dp, RoundedCornerShape(40.dp)).clip(RoundedCornerShape(40.dp))
            .background(MiuixTheme.colorScheme.surfaceContainer)
            .border(1.dp, MiuixTheme.colorScheme.outline.copy(alpha = 0.45f), RoundedCornerShape(40.dp))
            .padding(6.dp)) {
            val itemWidth = maxWidth / ConsolePage.entries.size
            val indicatorX by animateDpAsState(itemWidth * selected.ordinal,
                animationSpec = tween(300, easing = FastOutSlowInEasing), label = "navigation-indicator")
            Box(Modifier.offset(x = indicatorX).width(itemWidth).height(NavigationBarDefaults.ItemHeight)
                .clip(RoundedCornerShape(32.dp)).background(MiuixTheme.colorScheme.primaryContainer))
            NavigationBar(color = Color.Transparent, showDivider = false,
                defaultWindowInsetsPadding = false, mode = NavigationBarDisplayMode.IconWithSelectedLabel) {
                ConsolePage.entries.forEach { page ->
                    NavigationBarItem(selected = selected == page, onClick = { onSelect(page) }, label = page.label,
                        icon = when (page) {
                            ConsolePage.Home -> MiuixIcons.Home
                            ConsolePage.Settings -> MiuixIcons.Settings
                            ConsolePage.Diagnostics -> MiuixIcons.Search
                            ConsolePage.About -> MiuixIcons.Info
                        })
                }
            }
        }
    }
}

@Composable
internal fun StatusHero(state: ConsoleState, status: RadioStatus) {
    val title = when {
        state.op != null -> Messages.opTitle(state.op.kind)
        status.hotspotOn -> "热点运行中"
        status.hotspotState == HotspotState.Unresolved -> "需要恢复"
        !status.unifiedReady -> "等待就绪"
        status.hotspotState == HotspotState.Idle -> "热点已关闭"
        else -> "状态待确认"
    }
    val detail = when {
        state.op != null -> Messages.phase(state.op.phase)
        status.hotspotOn -> "${if (status.hotspotBand == "6g") "6GHz" else "其他频段"} · ${status.hotspotWidth?.let { "$it MHz" } ?: "带宽待确认"}"
        !status.unifiedReady -> Messages.reason(status.unifiedReason)
        status.hotspotState == HotspotState.Idle -> if (status.sixReady) "6GHz 已启用 · 按需开启共享" else "开启热点时将先启用 6GHz"
        else -> Presentation.hotspotSummary(state)
    }
    val heroInk = MiuixTheme.colorScheme.onPrimaryContainer
    Box(Modifier.padding(horizontal = 16.dp).padding(bottom = 14.dp).fillMaxWidth()
        .clip(RoundedCornerShape(28.dp)).background(MiuixTheme.colorScheme.primaryContainer)) {
        Canvas(Modifier.matchParentSize()) {
            val c = Offset(size.width * 0.93f, size.height * 0.58f)
            for (radius in listOf(45f, 85f, 125f)) {
                drawCircle(heroInk.copy(alpha = 0.07f), radius * density, c, style = Stroke(15f * density))
            }
        }
        Column(Modifier.padding(22.dp).fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("MT6639  /  WIRELESS", color = heroInk.copy(alpha = 0.8f), fontSize = 11.sp, letterSpacing = 1.5.sp)
            Text(title, color = heroInk, fontSize = 28.sp, fontWeight = FontWeight.SemiBold)
            Text(detail, color = heroInk.copy(alpha = 0.85f), fontSize = 13.sp, modifier = Modifier.widthIn(max = 300.dp))
        }
    }
}

@Composable
internal fun RadioMetrics(status: RadioStatus) {
    Row(Modifier.padding(horizontal = 16.dp).padding(bottom = 18.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        MetricTile(if (status.sixReady) "已启用" else "未就绪", "6GHz 频段", Modifier.weight(1f))
        MetricTile(if (status.hotspotOn) status.hotspotWidth?.let { "$it MHz" } ?: "待确认" else "${status.prefWidth} MHz",
            if (status.hotspotOn) "热点配置带宽" else "下次启动带宽", Modifier.weight(1f))
    }
}

@Composable
private fun MetricTile(value: String, label: String, modifier: Modifier) {
    Card(modifier = modifier, cornerRadius = 24.dp, insideMargin = PaddingValues(20.dp)) {
        Text(value, fontSize = 24.sp, fontWeight = FontWeight.Medium, color = MiuixTheme.colorScheme.primary)
        Text(label, fontSize = 12.sp, color = MiuixTheme.colorScheme.onSurfaceVariantSummary, modifier = Modifier.padding(top = 8.dp))
    }
}

@Composable
internal fun DetailRow(label: String, value: String, last: Boolean = false) {
    Column(Modifier.padding(horizontal = 20.dp)) {
        Row(Modifier.fillMaxWidth().padding(vertical = 17.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(18.dp)) {
            Text(label, fontSize = 15.sp, modifier = Modifier.weight(0.9f))
            Text(value, fontSize = 14.sp, color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                textAlign = TextAlign.End, modifier = Modifier.weight(1.1f))
        }
        if (!last) Box(Modifier.fillMaxWidth().height(0.5.dp).background(MiuixTheme.colorScheme.outline.copy(alpha = 0.4f)))
    }
}

@Composable
internal fun GroupIcon(icon: ImageVector) {
    Box(Modifier.padding(end = 14.dp).size(32.dp), contentAlignment = Alignment.Center) {
        Icon(icon, contentDescription = null, tint = MiuixTheme.colorScheme.primary, modifier = Modifier.size(23.dp))
    }
}

@Composable
internal fun OverviewCard(status: RadioStatus, onDiagnostics: () -> Unit) {
    val conditions = Presentation.conditions(status)
    val blocked = conditions.count { it.ok == false }
    val unknown = conditions.count { it.ok == null }
    Card(modifier = Modifier.padding(horizontal = 16.dp).padding(bottom = 16.dp), cornerRadius = 24.dp) {
        DetailRow("上游网络", when (status.upstream) { "cell" -> "移动数据"; "wifi", "wifi-any" -> "无线网络"; else -> "待确认" })
        DetailRow("设备适配", when(status.identity) { true -> "已匹配"; false -> "不匹配"; null -> "待检查" })
        DetailRow("热点密码", if (status.apKey) "已配置" else "未配置", last = true)
        ArrowPreference(title = when {
            blocked > 0 -> "$blocked 项条件需处理"
            unknown > 0 -> "$unknown 项条件待确认"
            else -> "运行条件"
        }, startAction = { GroupIcon(MiuixIcons.Search) }, onClick = onDiagnostics)
    }
}

@Composable
internal fun AboutCard(status: RadioStatus?) {
    val uriHandler = LocalUriHandler.current
    val project = "https://github.com/xiatian410/mt6639-wifi7-dijun"
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(
            Modifier.fillMaxWidth().padding(vertical = 28.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Card(insideMargin = PaddingValues(18.dp)) {
                Icon(MiuixIcons.Info, contentDescription = null,
                    tint = MiuixTheme.colorScheme.primary, modifier = Modifier.size(44.dp))
            }
            Text("MT6639", style = MiuixTheme.textStyles.headline1)
            Text("无线控制台", style = MiuixTheme.textStyles.body1)
            Text("6GHz 与热点，一处管理", style = MiuixTheme.textStyles.body2,
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
        }
        Text("版本信息", modifier = Modifier.padding(horizontal = 16.dp),
            style = MiuixTheme.textStyles.footnote1,
            color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
        Card {
            BasicComponent(title = "模块版本", summary = status?.let { Presentation.versions(it) } ?: "尚未读取设备状态")
            BasicComponent(title = "界面版本", summary = "Miuix 0.9.4 · 导航重设计测试版")
        }
        Text("项目与支持", modifier = Modifier.padding(horizontal = 16.dp),
            style = MiuixTheme.textStyles.footnote1,
            color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
        Card {
            ArrowPreference(title = "项目源码", summary = "xiatian410 / mt6639-wifi7-dijun",
                onClick = { uriHandler.openUri(project) })
            ArrowPreference(title = "问题反馈", summary = "前往 GitHub Issues；提交前请去除日志中的敏感信息",
                onClick = { uriHandler.openUri("$project/issues") })
            ArrowPreference(title = "开源许可", summary = "GNU GPL v3 · 查看项目许可原文",
                onClick = { uriHandler.openUri("$project/blob/main/LICENSE") })
        }
        Text("致谢", modifier = Modifier.padding(horizontal = 16.dp),
            style = MiuixTheme.textStyles.footnote1,
            color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
        Card {
            ArrowPreference(title = "Miuix", summary = "Compose Multiplatform UI · Apache-2.0",
                onClick = { uriHandler.openUri("https://github.com/miuix-kotlin-multiplatform/miuix") })
            BasicComponent(title = "Compose Multiplatform", summary = "由 Kotlin 与 Compose 驱动的 WebUI")
        }
        Text("开源构建 · 非官方系统组件", modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp),
            textAlign = TextAlign.Center, style = MiuixTheme.textStyles.footnote1,
            color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
    }
}
