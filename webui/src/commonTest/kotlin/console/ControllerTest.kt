package console

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The whole page logic against the simulated phone. */
@OptIn(ExperimentalCoroutinesApi::class)
class ControllerTest {
    /** Records every command and can replace an answer. */
    private class Spy(private val inner: Backend) : Backend {
        override val demo: Boolean get() = inner.demo
        val commands = ArrayList<String>()
        var running = 0
        var maxRunning = 0
        var override: (suspend (String, (Boolean, String) -> Unit) -> Int?)? = null

        override suspend fun run(command: String, onLine: (stderr: Boolean, text: String) -> Unit): Int {
            commands += command
            running++
            maxRunning = maxOf(maxRunning, running)
            try {
                override?.invoke(command, onLine)?.let { return it }
                return inner.run(command, onLine)
            } finally {
                running--
            }
        }

        val operations: List<String> get() = commands.map { it.substringAfterLast("mt6639-hotspot ") }
            .filterNot { it.startsWith("status") }
    }

    @Test
    fun demoStatusUsesExactlyTheDeclaredKeys() = runTest {
        for (scenario in listOf("", "ready", "active", "off", "sta5g", "nodata", "unresolved")) {
            val text = StringBuilder()
            assertEquals(0, DemoBackend(scenario).run(Commands.STATUS_FULL) { _, line -> text.append(line).append('\n') })
            assertEquals(STATUS_KEYS.toSet(), keyValues(text.toString()).keys, scenario)
            assertNotNull(parseStatus(text.toString()), scenario)
        }
    }

    @Test
    fun oneTapStartReportsItsStepsAndStopReturnsBothLayers() = runTest {
        val spy = Spy(DemoBackend("off"))
        val c = ConsoleController(spy, this)
        c.refresh().join()
        var s = assertNotNull(c.state.value.status)
        assertFalse(s.sixReady)
        assertEquals("已关闭 · 开启时会先启用 6GHz", Presentation.hotspotSummary(c.state.value))
        assertFalse(Presentation.hotspotChecked(c.state.value))
        assertTrue(Presentation.hotspotEnabled(c.state.value))

        val phases = ArrayList<String>()
        val watcher = launch { c.state.collect { st -> st.op?.phase?.let { if (phases.lastOrNull() != it) phases += it } } }
        val job = assertNotNull(c.setHotspot(true))
        runCurrent()
        // While it runs: the switch already shows the target and everything is locked.
        assertTrue(Presentation.hotspotChecked(c.state.value))
        assertFalse(Presentation.hotspotEnabled(c.state.value))
        assertFalse(Presentation.sixEnabled(c.state.value))
        assertFalse(Presentation.widthEnabled(c.state.value))
        assertNull(c.setHotspot(false), "a second operation is not started")
        assertNull(c.chooseWidth(160))
        job.join()
        watcher.cancel()
        assertEquals(listOf("", "preflight", "six_enable", "sta_settle", "hotspot_start", "verify"), phases)
        s = assertNotNull(c.state.value.status)
        assertNull(c.state.value.op)
        assertNull(c.state.value.notice)
        assertTrue(s.hotspotOn && s.sixReady && s.sessionOwns6g)
        assertEquals("已开启 · 20 MHz · 信道 37（6135 MHz）", Presentation.hotspotSummary(c.state.value))
        assertEquals("已启用 · 由一键开启启用，关闭热点时一并恢复 · 热点运行期间不能切换", Presentation.sixSummary(c.state.value))
        assertFalse(Presentation.sixEnabled(c.state.value))

        assertNotNull(c.setHotspot(false)).join()
        s = assertNotNull(c.state.value.status)
        assertFalse(s.hotspotOn || s.sixReady || s.sessionOwns6g)
        assertEquals(listOf("start 20", "stop"), spy.operations)
        assertEquals(1, spy.maxRunning, "commands never overlap")
    }

    @Test
    fun aRefusedStartExplainsItselfAndChangesNothing() = runTest {
        val spy = Spy(DemoBackend(""))
        val c = ConsoleController(spy, this)
        c.refresh().join()
        assertEquals(1, Presentation.blocking(assertNotNull(c.state.value.status)))
        assertNotNull(c.setHotspot(true)).join()
        val notice = assertNotNull(c.state.value.notice)
        assertEquals("热点没有开启", notice.title)
        assertTrue("还没有设置热点密码" in notice.message)
        assertTrue("返回码 66" in notice.message)
        assertEquals("REJECT ap_key_missing", notice.details)
        assertFalse(assertNotNull(c.state.value.status).hotspotOn)
        c.dismissNotice()
        assertNull(c.state.value.notice)

        // After setting a passphrase the same tap works; the passphrase is
        // sent as hex and never kept in the page state.
        assertNull(c.savePassphrase("short"))
        assertNotNull(c.savePassphrase("correct horse")).join()
        assertTrue(assertNotNull(c.state.value.status).apKey)
        assertEquals(0, Presentation.blocking(assertNotNull(c.state.value.status)))
        assertFalse(c.state.value.toString().contains("correct horse"))
        assertTrue(spy.commands.any { it.startsWith("echo 636f727265637420686f727365 | ") })
        assertNotNull(c.setHotspot(true)).join()
        assertTrue(assertNotNull(c.state.value.status).hotspotOn)
    }

    @Test
    fun nameSaveRoundTripsAndOnlyRunsWhileIdle() = runTest {
        val spy = Spy(DemoBackend("ready"))
        val c = ConsoleController(spy, this)
        assertNull(c.saveName("new"), "not loaded")
        assertTrue(spy.commands.isEmpty())
        c.refresh().join()
        for (bad in listOf("", "中".repeat(11), "bad\nname", "\uD800")) assertNull(c.saveName(bad))
        val name = "中文😀 '\$(id);`id`"
        val save = assertNotNull(c.saveName(name))
        assertEquals(OpKind.SetName, c.state.value.op?.kind)
        assertFalse(Presentation.nameEnabled(c.state.value))
        assertNull(c.saveName("another"))
        save.join()
        assertNull(c.state.value.notice)
        assertEquals(name, assertNotNull(c.state.value.status).ssid)
        assertEquals(1, spy.commands.count { it == Commands.setName(name) })
        assertNotNull(c.chooseWidth(160)).join()
        assertEquals(name, assertNotNull(c.state.value.status).ssid, "custom names do not change with width")
        assertNotNull(c.setHotspot(true)).join()
        assertEquals(name, assertNotNull(c.state.value.status).ssid)
        assertNull(c.saveName("running"))
        assertNotNull(c.setHotspot(false)).join()
        assertNotNull(c.saveName("next start")).join()
        assertEquals("next start", assertNotNull(c.state.value.status).ssid)
        assertEquals(1, spy.maxRunning)
    }

    @Test
    fun nameSaveRejectsBusyUnknownAndFailedStatus() = runTest {
        val inner = DemoBackend("ready", stepMs = 0)
        val spy = Spy(inner)
        val c = ConsoleController(spy, this)
        for (line in listOf("busy=1", "hotspot_state=unknown", "hotspot_state=starting", "hotspot_state=stopping", "hotspot_state=unresolved")) {
            spy.override = { command, out ->
                inner.run(command) { e, text ->
                    out(e, if (text.substringBefore('=') == line.substringBefore('=')) line else text)
                }
            }
            c.refresh().join()
            assertNull(c.saveName("blocked"), line)
        }
        spy.override = { _, _ -> 127 }
        c.refresh().join()
        assertNull(c.saveName("failed"))
        assertTrue(spy.commands.all { it == Commands.STATUS_FULL })
    }

    @Test
    fun queuedNameSaveRechecksStatusAndReportsBackendRefusal() = runTest {
        val inner = DemoBackend("ready")
        val spy = Spy(inner)
        val c = ConsoleController(spy, this)
        c.refresh().join()
        spy.override = { command, out ->
            if (command == Commands.STATUS_FULL) inner.run(command) { e, line ->
                out(e, if (line == "hotspot_state=idle") "hotspot_state=active" else line)
            } else null
        }
        val refresh = c.refresh()
        runCurrent()
        val save = assertNotNull(c.saveName("queued"))
        refresh.join()
        save.join()
        assertFalse(spy.commands.any { it.endsWith(Commands.SET_NAME_SUFFIX) })
        assertEquals("网络名称没有保存", assertNotNull(c.state.value.notice).title)
        spy.override = null
        c.refresh().join()
        spy.override = { command, out ->
            if (command.endsWith(Commands.SET_NAME_SUFFIX)) {
                out(true, "REJECT name_unwritable")
                74
            } else null
        }
        assertNotNull(c.saveName("refused")).join()
        assertNull(assertNotNull(c.state.value.status).customSsid)
        assertEquals("REJECT name_unwritable", assertNotNull(c.state.value.notice).details)
    }

    @Test
    fun demoRejectsMalformedNameCommandsAndChangesWhileActive() = runTest {
        val demo = DemoBackend("ready", stepMs = 0)
        assertEquals(65, demo.run("echo c080${Commands.SET_NAME_SUFFIX}") { _, _ -> })
        assertEquals(0, demo.run(Commands.start(20)) { _, _ -> })
        assertEquals(73, demo.run(Commands.setName("blocked")) { _, _ -> })
    }

    @Test
    fun stationOnAnotherBandIsShownBeforeAndExplainedAfter() = runTest {
        val c = ConsoleController(DemoBackend("sta5g"), this)
        c.refresh().join()
        val blocked = Presentation.conditions(assertNotNull(c.state.value.status)).single { it.ok == false }
        assertEquals("上游网络", blocked.title)
        assertNotNull(c.setHotspot(true)).join()
        val notice = assertNotNull(c.state.value.notice)
        assertTrue("当前 5180 MHz" in notice.message)
    }

    @Test
    fun sixSwitchWidthAndLogs() = runTest {
        val spy = Spy(DemoBackend("ready"))
        val c = ConsoleController(spy, this)
        c.refresh().join()
        assertTrue(Presentation.sixChecked(c.state.value) && Presentation.sixEnabled(c.state.value))
        assertTrue(Presentation.sixRefreshEnabled(c.state.value))
        assertNotNull(c.chooseWidth(160)).join()
        assertEquals(160, assertNotNull(c.state.value.status).prefWidth)
        assertEquals("MT6639-Native-6g-160", assertNotNull(c.state.value.status).ssid)
        assertNull(c.chooseWidth(160), "unchanged")
        assertNull(c.chooseWidth(30), "not a width")
        assertNotNull(c.refreshSix()).join()
        assertNotNull(c.setSix(false)).join()
        assertFalse(Presentation.sixChecked(c.state.value))
        assertEquals("未启用", Presentation.sixSummary(c.state.value))
        assertFalse(Presentation.sixRefreshEnabled(c.state.value))
        assertNotNull(c.setSix(true)).join()
        // 6GHz enabled by its own switch is not handed back with the hotspot.
        assertNotNull(c.setHotspot(true)).join()
        assertNotNull(c.setHotspot(false)).join()
        assertTrue(assertNotNull(c.state.value.status).sixReady)
        assertEquals(listOf("set-width 160", "six-refresh", "six-off", "six-on", "start 160", "stop"), spy.operations)

        assertNotNull(c.openLogs()).join()
        assertTrue("=== radio ===" in assertNotNull(c.state.value.logs))
        c.closeLogs()
        assertNull(c.state.value.logs)
    }

    @Test
    fun missingControllerOrBrokenStatusNeverLeavesAStaleReading() = runTest {
        val spy = Spy(DemoBackend("ready"))
        val c = ConsoleController(spy, this)
        c.refresh().join()
        assertNotNull(c.state.value.status)
        spy.override = { _, onLine -> onLine(true, "sh: not found"); 127 }
        c.refresh().join()
        assertNull(c.state.value.status)
        assertTrue("找不到控制脚本" in assertNotNull(c.state.value.statusProblem))
        assertFalse(Presentation.hotspotEnabled(c.state.value))
        spy.override = { _, onLine -> onLine(false, "schema=mt6639-radio-status-v1"); 0 }
        c.refresh().join()
        assertTrue("不完整" in assertNotNull(c.state.value.statusProblem))
        spy.override = null
        c.refresh().join()
        assertNotNull(c.state.value.status)
        assertNull(c.state.value.statusProblem)
        assertTrue(c.state.value.loaded)
    }

    @Test
    fun anOperationThatNeverEndsIsReportedAndThePageRecovers() = runTest {
        val spy = Spy(DemoBackend("ready"))
        val c = ConsoleController(spy, this, opTimeoutMs = 5_000L)
        c.refresh().join()
        spy.override = { command, _ -> if ("start" in command) { kotlinx.coroutines.awaitCancellation() } else null }
        assertNotNull(c.setHotspot(true)).join()
        assertNull(c.state.value.op)
        assertTrue("没有等到操作结束" in assertNotNull(c.state.value.notice).message)
        assertNotNull(c.state.value.status)
    }

    @Test
    fun pollingAlternatesLightAndFullAndPausesWhenHidden() = runTest {
        // Instant answers, so the schedule alone decides what runs when.
        val spy = Spy(DemoBackend("ready", stepMs = 0L))
        val c = ConsoleController(spy, this)
        var visible = true
        val poll = launch { c.poll({ visible }, intervalMs = 1_000L, fullEvery = 3) }
        advanceTimeBy(6_500L)
        val statuses = spy.commands.map { it.substringAfterLast("mt6639-hotspot ") }
        assertEquals(listOf("status full", "status", "status", "status full", "status", "status", "status full"), statuses)
        visible = false
        val seen = spy.commands.size
        advanceTimeBy(5_000L)
        assertEquals(seen, spy.commands.size)
        poll.cancel()
    }

    @Test
    fun aLightStatusWithoutASnapshotAsksTheControllerOnce() = runTest {
        val spy = Spy(DemoBackend("ready"))
        val c = ConsoleController(spy, this)
        spy.override = { command, onLine ->
            if (command == Commands.STATUS) {
                DemoBackend("ready").run(command) { e, line ->
                    onLine(e, if (line == "hotspot_snapshot=1") "hotspot_snapshot=0" else line)
                }
            } else {
                null
            }
        }
        val poll = launch { c.poll({ true }, intervalMs = 1_000L, fullEvery = 100) }
        advanceTimeBy(1_500L)
        poll.cancel()
        assertEquals(
            listOf("status full", "status", "status full"),
            spy.commands.map { it.substringAfterLast("mt6639-hotspot ") },
        )
    }
}
