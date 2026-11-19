package console

import androidx.compose.foundation.layout.*
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.style.TextAlign
import top.yukonga.miuix.kmp.icon.MiuixIcons
import top.yukonga.miuix.kmp.icon.extended.Home
import top.yukonga.miuix.kmp.icon.extended.Settings
import top.yukonga.miuix.kmp.icon.extended.Search
import top.yukonga.miuix.kmp.icon.extended.Info
import androidx.compose.runtime.Composable
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
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        NavigationBar(
            modifier = Modifier.widthIn(max = 720.dp),
            mode = NavigationBarDisplayMode.IconAndText,
        ) {
            ConsolePage.entries.forEach { page ->
                NavigationBarItem(
                    selected = selected == page,
                    onClick = { onSelect(page) },
                    icon = when (page) {
                        ConsolePage.Home -> MiuixIcons.Home
                        ConsolePage.Settings -> MiuixIcons.Settings
                        ConsolePage.Diagnostics -> MiuixIcons.Search
                        ConsolePage.About -> MiuixIcons.Info
                    },
                    label = page.label,
                )
            }
        }
    }
}

@Composable
internal fun OverviewCard(state: ConsoleState, status: RadioStatus, onDiagnostics: () -> Unit) {
    val conditions = Presentation.conditions(status)
    val blocked = conditions.count { it.ok == false }
    val unknown = conditions.count { it.ok == null }
    Card(modifier = Modifier.padding(horizontal = 12.dp).padding(bottom = 12.dp),
        insideMargin = PaddingValues(20.dp)) {
        Text("无线概览", style = MiuixTheme.textStyles.headline1)
        Text("热点：${Presentation.hotspotSummary(state)}\n6GHz：${Presentation.sixSummary(state)}", style = MiuixTheme.textStyles.body2,
            color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
            modifier = Modifier.padding(top = 6.dp, bottom = 16.dp))
        ArrowPreference(title = when {
            blocked > 0 -> "$blocked 项运行条件需处理"
            unknown > 0 -> "$unknown 项运行条件待确认"
            else -> "查看运行条件"
        }, summary = "查看检查详情与日志；条件通过不等于客户端已联网", onClick = onDiagnostics)
    }
}

@Composable
internal fun AboutCard(status: RadioStatus?) {
    val uriHandler = LocalUriHandler.current
    val project = "https://github.com/xiatian410/mt6639-wifi7-dijun"
    Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
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
