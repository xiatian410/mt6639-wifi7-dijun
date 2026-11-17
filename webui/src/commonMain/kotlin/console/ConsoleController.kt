package console

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/** Where commands run: a KernelSU root shell on the phone, or a simulation. */
interface Backend {
    /** True when nothing here touches a device. The page says so. */
    val demo: Boolean

    /** Runs [command], passing each output line to [onLine], and returns the exit status. */
    suspend fun run(command: String, onLine: (stderr: Boolean, text: String) -> Unit): Int
}

enum class OpKind { Start, Stop, SixOn, SixOff, SixRefresh, SetWidth, SetKey, SetName }

/** An operation in progress and the step the script last announced. */
data class RunningOp(val kind: OpKind, val phase: String)

/** A failure to explain: what did not happen, why, and the script's own output. */
data class Notice(val title: String, val message: String, val details: String)

data class ConsoleState(
    val demo: Boolean,
    /** The first status attempt has finished, successfully or not. */
    val loaded: Boolean = false,
    val status: RadioStatus? = null,
    /** Why there is no status to show. */
    val statusProblem: String? = null,
    val op: RunningOp? = null,
    val notice: Notice? = null,
    val logs: String? = null,
    val logsLoading: Boolean = false,
)

/**
 * Everything the page can do. Commands never overlap: a status check and an
 * operation from this page take turns, so the page cannot collide with itself
 * on the script's lock.
 */
class ConsoleController(
    private val backend: Backend,
    private val scope: CoroutineScope,
    // Covers bounded enable + AP start/stop + checked rollback, including
    // guardian recovery followed by a second journal-verified recovery attempt.
    private val opTimeoutMs: Long = 75 * 60_000L,
    private val statusTimeoutMs: Long = 90_000L,
) {
    private val _state = MutableStateFlow(ConsoleState(demo = backend.demo))
    val state: StateFlow<ConsoleState> get() = _state
    private val gate = Mutex()

    fun refresh(): Job = scope.launch { readStatus(full = true) }

    fun setHotspot(on: Boolean): Job? =
        if (on) {
            operate(OpKind.Start, Commands.start(_state.value.status?.prefWidth ?: 20))
        } else {
            operate(OpKind.Stop, Commands.STOP)
        }

    fun setSix(on: Boolean): Job? =
        if (on) operate(OpKind.SixOn, Commands.SIX_ON) else operate(OpKind.SixOff, Commands.SIX_OFF)

    fun refreshSix(): Job? = operate(OpKind.SixRefresh, Commands.SIX_REFRESH)

    fun chooseWidth(width: Int): Job? {
        if (width !in WIDTHS || width == _state.value.status?.prefWidth) return null
        return operate(OpKind.SetWidth, Commands.setWidth(width))
    }

    /** The caller has already shown [passphraseProblem]; an unacceptable value is not sent. */
    fun savePassphrase(passphrase: String): Job? {
        if (passphraseProblem(passphrase) != null) return null
        return operate(OpKind.SetKey, Commands.setKey(passphrase))
    }

    /** Names apply on the next start, and must never be edited during a session. */
    fun saveName(name: String): Job? {
        if (ssidProblem(name) != null || !Presentation.nameEnabled(_state.value)) return null
        return operate(OpKind.SetName, Commands.setName(name))
    }

    fun dismissNotice() = _state.update { it.copy(notice = null) }

    fun openLogs(): Job? {
        if (_state.value.logsLoading) return null
        _state.update { it.copy(logs = "", logsLoading = true) }
        return scope.launch {
            val text = StringBuilder()
            val code = gate.withLock {
                withTimeoutOrNull(statusTimeoutMs) {
                    backend.run(Commands.LOGS) { _, line -> text.append(line).append('\n') }
                }
            }
            val shown = when {
                code == 0 && text.isNotBlank() -> text.toString().trimEnd()
                code == 0 -> "还没有日志。"
                else -> "读不到日志（" + Messages.reason(parseResult(emptyList(), code ?: -1).reason) + "）"
            }
            // Closed while loading: stay closed.
            _state.update { if (it.logsLoading) it.copy(logs = shown, logsLoading = false) else it }
        }
    }

    fun closeLogs() = _state.update { it.copy(logs = null, logsLoading = false) }

    /** Keeps the page current while it is visible. Never returns. */
    suspend fun poll(visible: () -> Boolean, intervalMs: Long = 6_000L, fullEvery: Int = 5) {
        var tick = 0
        while (true) {
            if (visible() && _state.value.op == null) {
                readStatus(full = tick % fullEvery == 0)
                tick++
            }
            delay(intervalMs)
        }
    }

    private fun operate(kind: OpKind, command: String): Job? {
        val before = _state.value
        if (before.op != null) return null
        _state.value = before.copy(op = RunningOp(kind, ""), notice = null)
        return scope.launch {
            val lines = ArrayList<String>()
            val code = gate.withLock {
                // A refresh queued before this save may have discovered a running hotspot.
                if (kind == OpKind.SetName && !Presentation.nameEnabled(_state.value.copy(op = null))) {
                    lines += "REJECT hotspot_not_idle"
                    return@withLock 73
                }
                withTimeoutOrNull(opTimeoutMs) {
                    backend.run(command) { stderr, text ->
                        lines += text
                        if (!stderr && text.startsWith("phase=")) {
                            val phase = text.substring(6)
                            _state.update { it.copy(op = RunningOp(kind, phase)) }
                        }
                    }
                }
            }
            val result = if (code == null) {
                OpResult(false, "wait", "no_exit", "none", -1)
            } else {
                parseResult(lines, code)
            }
            readStatus(full = true)
            _state.update {
                it.copy(
                    op = null,
                    notice = if (result.ok) null else failure(kind, result, lines),
                )
            }
        }
    }

    private fun failure(kind: OpKind, result: OpResult, lines: List<String>): Notice {
        // Phase and result markers are for the page, not for a person.
        val details = lines.filterNot { it.startsWith("phase=") || it.startsWith("result=") }
            .joinToString("\n").trim()
        val suffix = if (result.rc > 0) "（步骤 ${result.step}，返回码 ${result.rc}）" else ""
        return Notice(
            title = Messages.failureTitle(kind),
            message = Messages.reason(result.reason, result.detail) + suffix,
            details = details,
        )
    }

    private suspend fun readStatus(full: Boolean) {
        val out = StringBuilder()
        val code = gate.withLock {
            withTimeoutOrNull(statusTimeoutMs) {
                backend.run(if (full) Commands.STATUS_FULL else Commands.STATUS) { stderr, text ->
                    if (!stderr) out.append(text).append('\n')
                }
            }
        }
        val parsed = if (code == 0) parseStatus(out.toString()) else null
        _state.update { s ->
            if (parsed != null) {
                s.copy(loaded = true, status = parsed.withKnown(s.status), statusProblem = null)
            } else {
                val why = when {
                    code == null -> Messages.reason("no_exit")
                    code == 0 -> "控制脚本的状态输出不完整或版本不符。请重新安装本模块。"
                    else -> Messages.reason(parseResult(emptyList(), code).reason)
                }
                // Never act on a reading that is no longer confirmed.
                s.copy(loaded = true, status = null, statusProblem = why)
            }
        }
        // A light status relies on the published snapshot; without one, ask the
        // hotspot controller once.
        if (!full && parsed != null && !parsed.hotspotSnapshot) readStatus(full = true)
    }
}
