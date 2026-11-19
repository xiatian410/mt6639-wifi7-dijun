package console

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.unit.dp
import top.yukonga.miuix.kmp.basic.BasicComponent
import top.yukonga.miuix.kmp.basic.ButtonDefaults
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.CardDefaults
import top.yukonga.miuix.kmp.basic.Icon
import top.yukonga.miuix.kmp.basic.IconButton
import top.yukonga.miuix.kmp.basic.InfiniteProgressIndicator
import top.yukonga.miuix.kmp.basic.LinearProgressIndicator
import top.yukonga.miuix.kmp.basic.MiuixScrollBehavior
import top.yukonga.miuix.kmp.basic.Scaffold
import top.yukonga.miuix.kmp.basic.SmallTitle
import top.yukonga.miuix.kmp.basic.Text
import top.yukonga.miuix.kmp.basic.TextButton
import top.yukonga.miuix.kmp.basic.TopAppBar
import top.yukonga.miuix.kmp.icon.MiuixIcons
import top.yukonga.miuix.kmp.icon.extended.Refresh
import top.yukonga.miuix.kmp.icon.extended.Home
import top.yukonga.miuix.kmp.icon.extended.Settings
import top.yukonga.miuix.kmp.icon.extended.Search
import top.yukonga.miuix.kmp.icon.extended.Info
import top.yukonga.miuix.kmp.icon.extended.Lock
import top.yukonga.miuix.kmp.icon.extended.Edit
import top.yukonga.miuix.kmp.icon.extended.Filter
import top.yukonga.miuix.kmp.icon.extended.Link
import top.yukonga.miuix.kmp.overlay.OverlayBottomSheet
import top.yukonga.miuix.kmp.overlay.OverlayDialog
import top.yukonga.miuix.kmp.preference.ArrowPreference
import top.yukonga.miuix.kmp.preference.OverlayDropdownPreference
import top.yukonga.miuix.kmp.preference.SwitchPreference
import top.yukonga.miuix.kmp.theme.ColorSchemeMode
import top.yukonga.miuix.kmp.theme.MiuixTheme
import top.yukonga.miuix.kmp.theme.TextStyles
import top.yukonga.miuix.kmp.theme.ThemeController
import top.yukonga.miuix.kmp.utils.overScrollVertical

private fun Color.css(): String = "#" + toArgb().toUInt().toString(16).padStart(8, '0').drop(2)

@Composable
fun ConsoleApp(controller: ConsoleController, textStyles: TextStyles) {
    val state by controller.state.collectAsState()
    val theme = remember { ThemeController(ColorSchemeMode.MonetSystem, keyColor = Color(0xFF426B9C)) }
    MiuixTheme(controller = theme, textStyles = textStyles) {
        val colors = MiuixTheme.colorScheme
        androidx.compose.runtime.SideEffect {
            jsSetTheme(colors.background.css(), colors.surfaceContainer.css(), colors.onSurface.css(),
                colors.onSurfaceVariantSummary.css(), colors.outline.css(), colors.primary.css(),
                colors.onPrimary.css(), colors.secondaryContainer.css(), colors.error.css())
        }
        ConsoleScreen(state, controller)
    }
}

@Composable
private fun ConsoleScreen(state: ConsoleState, controller: ConsoleController) {
    val scrollBehavior = MiuixScrollBehavior()
    var page by remember { mutableStateOf(ConsolePage.Home) }
    var confirmSixOff by remember { mutableStateOf(false) }
    Scaffold(
        topBar = {
            TopAppBar(
                title = if (page == ConsolePage.Home) "MT6639" else page.label,
                scrollBehavior = scrollBehavior,
                actions = {
                    IconButton(onClick = { controller.refresh() }, enabled = state.op == null) {
                        Icon(imageVector = MiuixIcons.Refresh, contentDescription = "刷新状态")
                    }
                },
            )
        },
        bottomBar = { PageNavigation(page) { page = it } },
    ) { padding ->
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
            androidx.compose.animation.Crossfade(targetState = page,
                animationSpec = androidx.compose.animation.core.tween(180), label = "console-page") { shownPage ->
            val pageScroll = androidx.compose.foundation.lazy.rememberLazyListState()
            LazyColumn(
                state = pageScroll,
                modifier = Modifier
                    .widthIn(max = 720.dp)
                    .fillMaxHeight()
                    .overScrollVertical()
                    .nestedScroll(scrollBehavior.nestedScrollConnection),
                contentPadding = PaddingValues(
                    top = padding.calculateTopPadding(),
                    bottom = padding.calculateBottomPadding() + 32.dp,
                ),
            ) {
                if (state.demo) {
                    item(key = "demo") { DemoBanner() }
                }
                val status = state.status
                if (state.op != null) {
                    item(key = "operation") {
                        Section {
                            BasicComponent(title = "正在执行", summary = Messages.phase(state.op.phase))
                            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                        }
                    }
                }
                when {
                    shownPage == ConsolePage.About -> item(key = "about") { AboutCard(status) }
                    shownPage == ConsolePage.Diagnostics -> {
                        if (status != null) {
                            if (status.sixCard.isNotBlank()) {
                                item(key = "six-detail") {
                                    Section { BasicComponent(title = "6GHz 模块状态", summary = Presentation.cardText(status.sixCard)) }
                                }
                            }
                            item(key = "conditions") { ConditionsCard(status) }
                        } else if (state.loaded) {
                            item(key = "problem") {
                                ProblemCard(state.statusProblem.orEmpty()) { controller.refresh() }
                            }
                        } else {
                            item(key = "loading") { LoadingCard() }
                        }
                        item(key = "more") { MoreCard(status, controller) }
                    }
                    !state.loaded -> item(key = "loading") { LoadingCard() }
                    status == null -> item(key = "problem") {
                        ProblemCard(state.statusProblem.orEmpty()) { controller.refresh() }
                    }
                    else -> {
                        when (shownPage) {
                            ConsolePage.Home -> {
                                item(key = "hero") { StatusHero(state, status) }
                                item(key = "metrics") { RadioMetrics(status) }
                                item(key = "hotspot") { HotspotCard(state, controller) }
                                item(key = "six") { SixCard(state, status, controller) { confirmSixOff = true } }
                                item(key = "overview") { OverviewCard(status) { page = ConsolePage.Diagnostics } }
                            }
                            ConsolePage.Settings -> {
                                item(key = "settings") { SettingsCard(state, status, controller) }
                                item(key = "settings-help") {
                                    Section { BasicComponent(title = "使用提示", startAction = { GroupIcon(MiuixIcons.Info) }, summary = "名称与带宽在下次开启时生效。客户端需支持 6GHz。") }
                                }
                            }
                            ConsolePage.Diagnostics -> Unit
                            ConsolePage.About -> Unit
                        }
                    }
                }
                item(key = "footer") { Footer() }
            }
            }
            ConfirmDialog(
                show = confirmSixOff,
                title = "关闭 6GHz？",
                summary = "模块会把 WLAN 配置恢复为原厂状态，并重启一次 WLAN。之后搜不到也连不上 6GHz 网络，直到重新启用。",
                confirm = "关闭 6GHz",
                onDismiss = { confirmSixOff = false },
                onConfirm = {
                    confirmSixOff = false
                    controller.setSix(false)
                },
            )
            NoticeDialog(state.notice) { controller.dismissNotice() }
            LogsSheet(state) { controller.closeLogs() }
        }
    }
}

@Composable
private fun Section(title: String? = null, content: @Composable ColumnScope.() -> Unit) {
    if (title != null) SmallTitle(text = title)
    Card(
        modifier = Modifier
            .padding(horizontal = 16.dp)
            .padding(bottom = 16.dp),
        cornerRadius = 24.dp,
        content = content,
    )
}

@Composable
private fun DemoBanner() {
    Card(
        modifier = Modifier
            .padding(horizontal = 12.dp)
            .padding(bottom = 12.dp),
        colors = CardDefaults.defaultColors(
            color = MiuixTheme.colorScheme.tertiaryContainer,
            contentColor = MiuixTheme.colorScheme.onTertiaryContainer,
        ),
        insideMargin = PaddingValues(16.dp),
    ) {
        Text(
            text = "演示模式",
            style = MiuixTheme.textStyles.headline1,
            color = MiuixTheme.colorScheme.onTertiaryContainer,
        )
        Text(
            text = "这个页面没有连接手机，下面全部是模拟数据，任何操作都不会影响设备。在 KernelSU 管理器里打开本模块的 WebUI，才是在控制真机。",
            style = MiuixTheme.textStyles.body2,
            color = MiuixTheme.colorScheme.onTertiaryContainer,
            modifier = Modifier.padding(top = 6.dp),
        )
    }
}

@Composable
private fun LoadingCard() {
    Section {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(24.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            InfiniteProgressIndicator(color = MiuixTheme.colorScheme.onSurfaceVariantSummary)
            Text(
                text = "正在读取状态",
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                modifier = Modifier.padding(start = 12.dp),
            )
        }
    }
}

@Composable
private fun ProblemCard(problem: String, onRetry: () -> Unit) {
    Section {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(text = "读不到状态", style = MiuixTheme.textStyles.headline1)
            Text(
                text = problem,
                style = MiuixTheme.textStyles.body2,
                color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                modifier = Modifier.padding(top = 6.dp, bottom = 16.dp),
            )
            TextButton(
                text = "重试",
                onClick = onRetry,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.textButtonColorsPrimary(),
            )
        }
    }
}

@Composable
private fun HotspotCard(state: ConsoleState, controller: ConsoleController) {
    Section {
        SwitchPreference(
            title = "6GHz 热点",
            startAction = { GroupIcon(MiuixIcons.Link) },
            summary = Presentation.hotspotSummary(state),
            checked = Presentation.hotspotChecked(state),
            onCheckedChange = { controller.setHotspot(it) },
            enabled = Presentation.hotspotEnabled(state),
        )
    }
}

@Composable
private fun SettingsCard(
    state: ConsoleState,
    status: RadioStatus,
    controller: ConsoleController,
) {
    Section(title = "热点设置") {
        ArrowPreference(
            title = "网络名称",
            startAction = { GroupIcon(MiuixIcons.Edit) },
            summary = Presentation.nameSummary(state),
            onClick = {
                jsPromptInput("设置网络名称", "支持中文和表情，最多 32 个 UTF-8 字节。下次开启时生效。", status.ssid, false,
                    { ssidProblem(it).orEmpty() }, { controller.saveName(it) != null })
            },
            enabled = Presentation.nameEnabled(state),
        )
        OverlayDropdownPreference(
            title = "带宽",
            startAction = { GroupIcon(MiuixIcons.Filter) },
            summary = "越宽上限越高，也越依赖客户端和周围环境",
            items = WIDTHS.map { "$it MHz" },
            selectedIndex = WIDTHS.indexOf(status.prefWidth).coerceAtLeast(0),
            enabled = Presentation.widthEnabled(state),
            onSelectedIndexChange = { controller.chooseWidth(WIDTHS[it]) },
        )
        ArrowPreference(
            title = "热点密码",
            startAction = { GroupIcon(MiuixIcons.Lock) },
            summary = Presentation.keySummary(status),
            onClick = {
                jsPromptInput("设置热点密码", "8–63 位英文字母、数字或符号。保存后不会显示。", "", true,
                    { passphraseProblem(it).orEmpty() }, {
                        Presentation.keyEnabled(controller.state.value) && controller.savePassphrase(it) != null
                    })
            },
            enabled = Presentation.keyEnabled(state),
        )
    }
}

@Composable
private fun SixCard(
    state: ConsoleState,
    status: RadioStatus,
    controller: ConsoleController,
    onConfirmOff: () -> Unit,
) {
    Section(title = "6GHz 频段") {
        SwitchPreference(
            title = "6GHz",
            startAction = { GroupIcon(MiuixIcons.Settings) },
            summary = Presentation.sixSummary(state),
            checked = Presentation.sixChecked(state),
            onCheckedChange = { on -> if (on) controller.setSix(true) else onConfirmOff() },
            enabled = Presentation.sixEnabled(state),
        )
        ArrowPreference(
            title = "重新注册 6GHz",
            startAction = { GroupIcon(MiuixIcons.Refresh) },
            summary = "软重启后 6GHz 信道消失时使用，会重启一次 WLAN",
            onClick = { controller.refreshSix() },
            enabled = Presentation.sixRefreshEnabled(state),
        )
    }
}

@Composable
private fun ConditionsCard(status: RadioStatus) {
    Section(title = "运行条件") {
        for (condition in Presentation.conditions(status)) {
            BasicComponent(
                title = condition.title,
                summary = condition.summary,
                endActions = {
                    val (label, color) = when (condition.ok) {
                        true -> "正常" to MiuixTheme.colorScheme.primary
                        false -> "需处理" to MiuixTheme.colorScheme.error
                        null -> "未知" to MiuixTheme.colorScheme.onSurfaceVariantActions
                    }
                    Text(text = label, color = color, style = MiuixTheme.textStyles.body2)
                },
            )
        }
    }
}

@Composable
private fun MoreCard(status: RadioStatus?, controller: ConsoleController) {
    Section(title = "其他") {
        ArrowPreference(
            title = "查看日志",
            startAction = { GroupIcon(MiuixIcons.Search) },
            summary = "合并控制、热点、6GHz 三份记录的末尾",
            onClick = { controller.openLogs() },
        )
        BasicComponent(title = "版本", summary = status?.let { Presentation.versions(it) } ?: "尚未读取设备状态")
    }
}

@Composable
private fun Footer() {
    Text(
        text = "实验模块。这里显示的是模块自己的检查结果：热点显示为已开启，不代表客户端一定能连上或能上网。",
        style = MiuixTheme.textStyles.footnote1,
        color = MiuixTheme.colorScheme.onBackgroundVariant,
        modifier = Modifier
            .padding(horizontal = 28.dp)
            .padding(top = 4.dp),
    )
}

@Composable
private fun DialogButtons(
    cancel: String,
    confirm: String,
    confirmEnabled: Boolean = true,
    onCancel: () -> Unit,
    onConfirm: () -> Unit,
) {
    Row(horizontalArrangement = Arrangement.SpaceBetween) {
        TextButton(text = cancel, onClick = onCancel, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(20.dp))
        TextButton(
            text = confirm,
            onClick = onConfirm,
            modifier = Modifier.weight(1f),
            enabled = confirmEnabled,
            colors = ButtonDefaults.textButtonColorsPrimary(),
        )
    }
}

@Composable
private fun ConfirmDialog(
    show: Boolean,
    title: String,
    summary: String,
    confirm: String,
    onDismiss: () -> Unit,
    onConfirm: () -> Unit,
) {
    OverlayDialog(show = show, title = title, summary = summary, onDismissRequest = onDismiss) {
        DialogButtons(cancel = "取消", confirm = confirm, onCancel = onDismiss, onConfirm = onConfirm)
    }
}

@Composable
private fun NoticeDialog(notice: Notice?, onDismiss: () -> Unit) {
    // Keep the text while the dialog animates out.
    var shown by remember { mutableStateOf(notice) }
    if (notice != null) shown = notice
    val current = shown
    OverlayDialog(
        show = notice != null,
        title = current?.title,
        summary = current?.message,
        onDismissRequest = onDismiss,
    ) {
        Column {
            if (!current?.details.isNullOrBlank()) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 168.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(MiuixTheme.colorScheme.secondaryContainer)
                        .verticalScroll(rememberScrollState())
                        .padding(12.dp),
                ) {
                    Text(
                        text = current?.details.orEmpty(),
                        style = MiuixTheme.textStyles.footnote1,
                        color = MiuixTheme.colorScheme.onSecondaryContainer,
                    )
                }
                Spacer(Modifier.height(16.dp))
            }
            TextButton(
                text = "知道了",
                onClick = onDismiss,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.textButtonColorsPrimary(),
            )
        }
    }
}

@Composable
private fun LogsSheet(state: ConsoleState, onDismiss: () -> Unit) {
    OverlayBottomSheet(show = state.logs != null, title = "日志", onDismissRequest = onDismiss) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 120.dp, max = 520.dp)
                .verticalScroll(rememberScrollState())
                .padding(bottom = 16.dp),
        ) {
            if (state.logsLoading) {
                InfiniteProgressIndicator(
                    color = MiuixTheme.colorScheme.onSurfaceVariantSummary,
                    modifier = Modifier.align(Alignment.Center),
                )
            } else {
                Text(
                    text = state.logs.orEmpty(),
                    style = MiuixTheme.textStyles.footnote1,
                    color = MiuixTheme.colorScheme.onSurface,
                )
            }
        }
    }
}
