package console

import kotlinx.coroutines.delay

/**
 * A stand-in for the phone, used when the page is opened outside a KernelSU
 * manager. It answers the same commands in the same format as
 * `radio-control.sh`, so the whole page can be seen and tried in a desktop
 * browser. Nothing it reports comes from a device.
 */
class DemoBackend(
    scenario: String = "",
    private val stepMs: Long = 900L,
) : Backend {
    override val demo: Boolean = true

    private var sixModule = "present"
    private var sixActive = true
    private var sixSeq = 1
    private var owns = false
    private var hotspot = "idle"
    private var width = 20
    private var prefWidth = 20
    private var nameHex = ""
    private var apKey = false
    private var staFreq: Int? = null
    private var cellData = true
    private var missing = false

    init {
        when (scenario) {
            "ready" -> apKey = true
            "active" -> { apKey = true; hotspot = "active"; width = 160; prefWidth = 160 }
            "off" -> { apKey = true; sixActive = false }
            "sta5g" -> { apKey = true; staFreq = 5180 }
            "nodata" -> { apKey = true; cellData = false }
            "nosix" -> { apKey = true; sixModule = "missing"; sixActive = false }
            "unresolved" -> { apKey = true; hotspot = "unresolved" }
            "missing" -> missing = true
        }
    }

    override suspend fun run(command: String, onLine: (stderr: Boolean, text: String) -> Unit): Int {
        if (missing) {
            delay(stepMs / 3)
            onLine(true, "sh: ${Commands.MODULE}/bin/radio-control.sh: No such file or directory")
            return 127
        }
        if (command.endsWith(Commands.SET_NAME_SUFFIX)) {
            delay(stepMs / 2)
            val hex = command.removePrefix("echo ").removeSuffix(Commands.SET_NAME_SUFFIX)
            if (decodeSsidHex(hex) == null) {
                onLine(true, "REJECT name_encoding_invalid")
                return 65
            }
            if (hotspot != "idle") {
                onLine(true, "REJECT hotspot_not_idle")
                return 73
            }
            nameHex = hex
            onLine(false, "ssid_hex=$nameHex")
            return 0
        }
        if (command.endsWith(Commands.SET_KEY_SUFFIX)) {
            delay(stepMs / 2)
            apKey = true
            onLine(false, "ap_key=1")
            return 0
        }
        val args = command.removePrefix(Commands.STATUS.removeSuffix("status")).split(' ')
        val out: (String) -> Unit = { onLine(false, it) }
        return when (args[0]) {
            "status" -> { delay(stepMs / 6); status(args.getOrNull(1) == "full", out); 0 }
            "start" -> finish(start(args.getOrNull(1)?.toIntOrNull() ?: prefWidth, out, onLine), out)
            "stop" -> finish(stop(out), out)
            "six-on" -> finish(sixOn(out, onLine), out)
            "six-off" -> finish(sixOff(out, onLine), out)
            "six-refresh" -> finish(sixRefresh(out, onLine), out)
            "set-width" -> {
                prefWidth = args[1].toInt()
                out("pref_width=$prefWidth")
                finish(null, out)
            }
            "logs" -> {
                delay(stepMs / 3)
                out("=== radio ===")
                out("（演示模式：这里没有真实设备的日志）")
                out("=== hotspot ===")
                out("=== sixg ===")
                0
            }
            else -> 64
        }
    }

    /** A failure is step, reason, detail and exit status; null is success. */
    private class Failure(val step: String, val reason: String, val detail: String, val rc: Int)

    private fun finish(failure: Failure?, out: (String) -> Unit): Int {
        if (failure == null) {
            out("result=ok")
            return 0
        }
        out("result=failed step=${failure.step} reason=${failure.reason} detail=${failure.detail} rc=${failure.rc}")
        return failure.rc
    }

    private fun reject(onLine: (Boolean, String) -> Unit, step: String, reason: String, rc: Int, detail: String = "none"): Failure {
        onLine(true, "REJECT $reason")
        return Failure(step, reason, detail, rc)
    }

    private fun upstreamProblem(): Pair<String, String>? = when {
        staFreq == null && !cellData -> "cellular_data_unavailable" to "upstream=cell,sta_freq=none"
        staFreq != null && staFreq!! < 5950 -> "sta_band_incompatible_with_6g" to "upstream=wifi-any,sta_freq=$staFreq"
        else -> null
    }

    private suspend fun start(w: Int, out: (String) -> Unit, onLine: (Boolean, String) -> Unit): Failure? {
        out("phase=preflight")
        delay(stepMs)
        if (sixModule != "present") return reject(onLine, "preflight", "sixg_module_$sixModule", 66)
        if (!apKey) return reject(onLine, "preflight", "ap_key_missing", 66)
        if (hotspot == "active") {
            if (width == w) { out("combined=already_active width=$w"); return null }
            return reject(onLine, "preflight", "hotspot_active_other_profile", 73, "band=6g,width=$width")
        }
        if (hotspot != "idle") return reject(onLine, "preflight", "hotspot_not_idle", 73, "state=$hotspot")
        upstreamProblem()?.let { return reject(onLine, "preflight", it.first, 69, it.second) }
        if (!sixActive) {
            out("phase=six_enable")
            delay(stepMs * 3)
            sixActive = true
            sixSeq++
            owns = true
            out("phase=sta_settle")
            delay(stepMs * 2)
        }
        out("phase=hotspot_start")
        delay(stepMs * 3)
        out("phase=verify")
        delay(stepMs)
        hotspot = "active"
        width = w
        out("combined=active width=$w owns_6g=${if (owns) 1 else 0} freq=6135 channel=37")
        return null
    }

    private suspend fun stop(out: (String) -> Unit): Failure? {
        out("phase=hotspot_stop")
        delay(stepMs * 2)
        hotspot = "idle"
        if (owns) {
            out("phase=six_restore")
            delay(stepMs * 3)
            sixActive = false
            owns = false
            out("six=restored")
        }
        out("combined=idle")
        return null
    }

    private suspend fun sixOn(out: (String) -> Unit, onLine: (Boolean, String) -> Unit): Failure? {
        out("phase=six_enable")
        if (sixModule != "present") return reject(onLine, "six_enable", "sixg_module_$sixModule", 66)
        if (sixActive) { out("six=already_active"); return null }
        delay(stepMs * 3)
        sixActive = true
        sixSeq++
        out("six=active")
        return null
    }

    private suspend fun sixOff(out: (String) -> Unit, onLine: (Boolean, String) -> Unit): Failure? {
        out("phase=six_restore")
        if (hotspot != "idle") return reject(onLine, "six_restore", "hotspot_active", 73, "state=$hotspot")
        delay(stepMs * 3)
        sixActive = false
        owns = false
        out("six=restored")
        return null
    }

    private suspend fun sixRefresh(out: (String) -> Unit, onLine: (Boolean, String) -> Unit): Failure? {
        out("phase=six_refresh")
        if (hotspot != "idle") return reject(onLine, "six_refresh", "hotspot_active", 73, "state=$hotspot")
        if (!sixActive) return reject(onLine, "six_refresh", "state_not_active", 3)
        delay(stepMs * 3)
        out("six=refreshed")
        return null
    }

    private fun status(full: Boolean, out: (String) -> Unit) {
        val active = hotspot == "active"
        out("schema=$STATUS_SCHEMA")
        out("mode=${if (full) "full" else "light"}")
        out("boot=00000000-0000-4000-8000-000000000000")
        out("busy=0")
        out("six_module=$sixModule")
        out("six_version=${if (sixModule == "missing") "unknown" else "v0.3.3-dijun.1"}")
        if (sixModule != "missing") {
            out("six_status_rc=0")
            out("six_state=${if (sixActive) "active" else "restored"}")
            out("six_tx=${if (sixActive) "present" else "none"}")
            out("six_guardian=${if (sixActive) "alive" else "none"}")
            out("six_profile=demo")
            out("six_compat_error=none")
            out("six_boot_default=1")
            out("six_ready=${if (sixActive) 1 else 0}")
            out(
                "six_card=" + if (sixActive) {
                    "[事务运行] 适配：demo | 内核：匹配 | 驱动：匹配 | 配置：临时配置 | 事务：运行 | 6GHz：60个已注册信道 | 连接：" +
                        (staFreq?.let { "${it}MHz" } ?: "未连接") + " | 更新：演示数据。信道注册不代表业务通过。"
                } else {
                    "[已恢复] 适配：demo | 内核：匹配 | 驱动：匹配 | 配置：原厂 | 事务：空闲 | 6GHz：0个已注册信道 | 连接：" +
                        (staFreq?.let { "${it}MHz" } ?: "未连接") + " | 更新：演示数据。信道注册不代表业务通过。"
                },
            )
        }
        out("hotspot_module=present")
        out("hotspot_version=v0.3.0-dijun.1")
        if (full) {
            out("hotspot_status_rc=0")
            out("hotspot_state=$hotspot")
            out("hotspot_freq=${if (active) "6135" else "none"}")
            out("hotspot_channel=${if (active) "37" else "none"}")
        } else {
            out("hotspot_state=$hotspot")
        }
        out("hotspot_checked=${if (full) 1 else 0}")
        out("hotspot_snapshot=1")
        out("hotspot_band=${if (hotspot == "idle") "none" else "6g"}")
        out("hotspot_width=${if (hotspot == "idle") "none" else width.toString()}")
        out("hotspot_age=0")
        out("enforcing=1")
        out("ap_key=${if (apKey) 1 else 0}")
        if (full) {
            out("integrity=1")
            out("identity=1")
            out("identity_reason=none")
        }
        val problem = upstreamProblem()
        out("wifi=1")
        out("sta=${if (staFreq == null) "disconnected" else "connected"}")
        out("sta_freq=${staFreq ?: "none"}")
        out("upstream=${if (staFreq == null) "cell" else "wifi-any"}")
        out("upstream_ok=${if (problem == null) 1 else 0}")
        out("upstream_reason=${problem?.first ?: "none"}")
        out("cell_data=${if (staFreq == null) (if (cellData) "1" else "0") else "na"}")
        out("session_owns_6g=${if (owns) 1 else 0}")
        out("pref_width=$prefWidth")
        out("ssid_status_rc=0")
        out("ssid_hex=$nameHex")
        out("end=1")
    }
}
