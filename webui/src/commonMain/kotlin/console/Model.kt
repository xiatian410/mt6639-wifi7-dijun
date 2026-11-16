package console

/** 6GHz widths the hotspot controller accepts. */
val WIDTHS: List<Int> = listOf(20, 40, 80, 160, 320)

const val STATUS_SCHEMA = "mt6639-radio-status-v1"

/**
 * Every key the console reads from `radio-control.sh status`. A repository
 * test compares this list with what the script really prints.
 */
val STATUS_KEYS: List<String> = listOf(
    "schema", "mode", "boot", "busy",
    "six_module", "six_version", "six_status_rc", "six_state", "six_tx", "six_guardian",
    "six_profile", "six_compat_error", "six_boot_default", "six_ready", "six_card",
    "hotspot_module", "hotspot_version", "hotspot_status_rc", "hotspot_state",
    "hotspot_freq", "hotspot_channel", "hotspot_checked", "hotspot_snapshot",
    "hotspot_band", "hotspot_width", "hotspot_age",
    "enforcing", "ap_key", "integrity", "identity", "identity_reason",
    "wifi", "sta", "sta_freq", "upstream", "upstream_ok", "upstream_reason", "cell_data",
    "session_owns_6g", "pref_width", "end",
)

enum class ModuleState { Present, Disabled, Removing, Missing, Unknown }

enum class HotspotState { Idle, Starting, Active, Stopping, Unresolved, Disabled, Unknown }

enum class SixTx { None, Present, Invalid, Unknown }

/** One reading of both radio layers. Null means the script did not report the value. */
data class RadioStatus(
    val full: Boolean,
    val boot: String,
    val busy: Boolean,
    val sixModule: ModuleState,
    val sixVersion: String,
    val sixState: String,
    val sixTx: SixTx,
    val sixGuardian: String,
    val sixProfile: String,
    val sixCompatError: String,
    val sixBootDefault: Boolean?,
    val sixReady: Boolean,
    val sixCard: String,
    val hotspotModule: ModuleState,
    val hotspotVersion: String,
    val hotspotState: HotspotState,
    val hotspotChecked: Boolean,
    val hotspotSnapshot: Boolean,
    val hotspotBand: String,
    val hotspotWidth: Int?,
    val hotspotFreq: Int?,
    val hotspotChannel: Int?,
    val hotspotAge: Int?,
    val enforcing: Boolean,
    val apKey: Boolean,
    val integrity: Boolean?,
    val identity: Boolean?,
    val identityReason: String,
    val wifi: Boolean?,
    val staConnected: Boolean?,
    val staFreq: Int?,
    val upstream: String,
    val upstreamOk: Boolean,
    val upstreamReason: String,
    val cellData: Boolean?,
    val sessionOwns6g: Boolean,
    val prefWidth: Int,
) {
    /** The one-tap state: a 6GHz hotspot that the controller confirmed or published. */
    val hotspotOn: Boolean get() = hotspotState == HotspotState.Active

    /** Width shown for the network name: the running one, otherwise the saved choice. */
    val shownWidth: Int get() = if (hotspotOn) hotspotWidth ?: prefWidth else prefWidth

    val ssid: String get() = "MT6639-Native-6g-$shownWidth"
}

private fun flag(value: String?): Boolean? = when (value) {
    "1" -> true
    "0" -> false
    else -> null
}

private fun moduleState(value: String?): ModuleState = when (value) {
    "present" -> ModuleState.Present
    "disabled" -> ModuleState.Disabled
    "removing" -> ModuleState.Removing
    "missing" -> ModuleState.Missing
    else -> ModuleState.Unknown
}

private fun hotspotState(value: String?): HotspotState = when (value) {
    "idle" -> HotspotState.Idle
    "starting" -> HotspotState.Starting
    "active" -> HotspotState.Active
    "stopping" -> HotspotState.Stopping
    "unresolved" -> HotspotState.Unresolved
    "disabled" -> HotspotState.Disabled
    else -> HotspotState.Unknown
}

/** Splits `key=value` lines; the first occurrence of a key wins, as in the script's own readers. */
fun keyValues(text: String): Map<String, String> {
    val map = LinkedHashMap<String, String>()
    for (raw in text.lineSequence()) {
        val line = raw.trimEnd('\r')
        val split = line.indexOf('=')
        if (split <= 0) continue
        val key = line.substring(0, split)
        if (key !in map) map[key] = line.substring(split + 1)
    }
    return map
}

/** Returns null unless the output is a complete status of the expected schema. */
fun parseStatus(text: String): RadioStatus? {
    val f = keyValues(text)
    if (f["schema"] != STATUS_SCHEMA || f["end"] != "1") return null
    val width = f["hotspot_width"]?.toIntOrNull()?.takeIf { it in WIDTHS }
    return RadioStatus(
        full = f["mode"] == "full",
        boot = f["boot"].orEmpty(),
        busy = f["busy"] == "1",
        sixModule = moduleState(f["six_module"]),
        sixVersion = f["six_version"] ?: "unknown",
        sixState = f["six_state"] ?: "unknown",
        sixTx = when (f["six_tx"]) {
            "none" -> SixTx.None
            "present" -> SixTx.Present
            "invalid" -> SixTx.Invalid
            else -> SixTx.Unknown
        },
        sixGuardian = f["six_guardian"] ?: "unknown",
        sixProfile = f["six_profile"] ?: "unknown",
        sixCompatError = f["six_compat_error"] ?: "unknown",
        sixBootDefault = flag(f["six_boot_default"]),
        sixReady = f["six_ready"] == "1",
        sixCard = f["six_card"].orEmpty(),
        hotspotModule = moduleState(f["hotspot_module"]),
        hotspotVersion = f["hotspot_version"] ?: "unknown",
        hotspotState = hotspotState(f["hotspot_state"]),
        hotspotChecked = f["hotspot_checked"] == "1",
        hotspotSnapshot = f["hotspot_snapshot"] == "1",
        hotspotBand = f["hotspot_band"] ?: "none",
        hotspotWidth = width,
        hotspotFreq = f["hotspot_freq"]?.toIntOrNull(),
        hotspotChannel = f["hotspot_channel"]?.toIntOrNull(),
        hotspotAge = f["hotspot_age"]?.toIntOrNull(),
        enforcing = f["enforcing"] == "1",
        apKey = f["ap_key"] == "1",
        integrity = flag(f["integrity"]),
        identity = flag(f["identity"]),
        identityReason = f["identity_reason"] ?: "none",
        wifi = flag(f["wifi"]),
        staConnected = when (f["sta"]) {
            "connected" -> true
            "disconnected" -> false
            else -> null
        },
        staFreq = f["sta_freq"]?.toIntOrNull(),
        upstream = f["upstream"] ?: "unknown",
        upstreamOk = f["upstream_ok"] == "1",
        upstreamReason = f["upstream_reason"] ?: "none",
        cellData = flag(f["cell_data"]),
        sessionOwns6g = f["session_owns_6g"] == "1",
        prefWidth = f["pref_width"]?.toIntOrNull()?.takeIf { it in WIDTHS } ?: 20,
    )
}

/**
 * A light status has no checked hotspot fields, integrity or identity. Keep
 * what the last full status of the same boot established.
 */
fun RadioStatus.withKnown(previous: RadioStatus?): RadioStatus {
    if (previous == null || previous.boot != boot) return this
    return copy(
        integrity = integrity ?: previous.integrity,
        identity = identity ?: previous.identity,
        identityReason = if (identity == null) previous.identityReason else identityReason,
        hotspotFreq = hotspotFreq ?: previous.hotspotFreq?.takeIf { hotspotOn },
        hotspotChannel = hotspotChannel ?: previous.hotspotChannel?.takeIf { hotspotOn },
    )
}

/** Result line of a controller operation. */
data class OpResult(
    val ok: Boolean,
    val step: String,
    val reason: String,
    val detail: String,
    val rc: Int,
)

/**
 * Reads the single `result=` line. An operation that ended without one (the
 * script is missing, or it refused the caller before reaching its dispatcher)
 * is described by its exit status.
 */
fun parseResult(lines: List<String>, exitCode: Int): OpResult {
    val line = lines.lastOrNull { it.startsWith("result=") }
    if (line != null) {
        val f = line.split(' ').mapNotNull {
            val i = it.indexOf('=')
            if (i <= 0) null else it.substring(0, i) to it.substring(i + 1)
        }.toMap()
        if (f["result"] == "ok") return OpResult(true, "none", "none", "none", 0)
        return OpResult(
            ok = false,
            step = f["step"] ?: "none",
            reason = f["reason"] ?: "none",
            detail = f["detail"] ?: "none",
            rc = f["rc"]?.toIntOrNull() ?: exitCode,
        )
    }
    if (exitCode == 0) return OpResult(true, "none", "none", "none", 0)
    // The passphrase installer has no result line; its refusal is one token.
    val rejected = lines.lastOrNull { it.startsWith("REJECT ") }?.removePrefix("REJECT ")
        ?.takeWhile { it in 'a'..'z' || it in '0'..'9' || it == '_' }
    if (!rejected.isNullOrEmpty()) return OpResult(false, "command", rejected, "none", exitCode)
    val reason = when (exitCode) {
        64 -> "usage_rejected"
        66 -> "module_files_missing"
        70 -> "boot_id_unreadable"
        74 -> "work_directory_unwritable"
        77 -> "not_root_or_wrong_context"
        126, 127 -> "controller_missing"
        else -> "no_result"
    }
    return OpResult(false, "launch", reason, "none", exitCode)
}

/** Null when [passphrase] is acceptable, otherwise the reason shown under the field. */
fun passphraseProblem(passphrase: String): String? = when {
    passphrase.isEmpty() -> "请输入密码"
    passphrase.any { it !in ' '..'~' } -> "只能使用英文字母、数字和常见符号"
    passphrase.length < 8 -> "至少 8 位（还差 ${8 - passphrase.length} 位）"
    passphrase.length > 63 -> "最多 63 位"
    else -> null
}

/** Lowercase hex of printable ASCII; the only form in which a passphrase leaves the page. */
fun passphraseHex(passphrase: String): String {
    require(passphraseProblem(passphrase) == null)
    val digits = "0123456789abcdef"
    val out = StringBuilder(passphrase.length * 2)
    for (c in passphrase) {
        out.append(digits[c.code shr 4]).append(digits[c.code and 15])
    }
    return out.toString()
}
