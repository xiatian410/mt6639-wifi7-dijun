package console

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ModelTest {
    /** Shape of `radio-control.sh status full` with a running one-tap session. */
    private val full = """
        schema=mt6639-radio-status-v1
        mode=full
        boot=11111111-1111-4111-8111-111111111111
        busy=0
        six_module=present
        six_version=v0.3.3-dijun.1
        six_status_rc=0
        six_state=active
        six_tx=present
        six_guardian=alive
        six_profile=os4-g284297
        six_compat_error=none
        six_boot_default=1
        six_ready=1
        six_card=[事务运行] 适配：os4 | 内核：匹配 | 6GHz：60个已注册信道 | 更新：12:00:00。a=b
        hotspot_module=present
        hotspot_version=v0.3.0-dijun.1
        hotspot_status_rc=0
        hotspot_state=active
        hotspot_freq=6135
        hotspot_channel=37
        hotspot_checked=1
        hotspot_snapshot=1
        hotspot_band=6g
        hotspot_width=160
        hotspot_age=0
        enforcing=1
        ap_key=1
        integrity=1
        identity=1
        identity_reason=none
        wifi=1
        sta=disconnected
        sta_freq=none
        upstream=cell
        upstream_ok=1
        upstream_reason=none
        cell_data=1
        session_owns_6g=1
        pref_width=80
        end=1
    """.trimIndent()

    @Test
    fun parsesEveryFieldOfAFullStatus() {
        val s = assertNotNull(parseStatus(full))
        assertTrue(s.full)
        assertEquals(ModuleState.Present, s.sixModule)
        assertEquals(SixTx.Present, s.sixTx)
        assertTrue(s.sixReady)
        // A value may itself contain "=": only the first one separates.
        assertTrue(s.sixCard.endsWith("更新：12:00:00。a=b"))
        assertEquals(HotspotState.Active, s.hotspotState)
        assertEquals(160, s.hotspotWidth)
        assertEquals(6135, s.hotspotFreq)
        assertEquals(37, s.hotspotChannel)
        assertEquals(true, s.integrity)
        assertEquals(true, s.identity)
        assertEquals(true, s.wifi)
        assertEquals(false, s.staConnected)
        assertNull(s.staFreq)
        assertEquals("cell", s.upstream)
        assertEquals(true, s.cellData)
        assertTrue(s.sessionOwns6g)
        assertEquals(80, s.prefWidth)
        // The running width names the network, not the saved preference.
        assertEquals("MT6639-Native-6g-160", s.ssid)
    }

    @Test
    fun everyDeclaredKeyIsPresentInTheSample() {
        val keys = keyValues(full).keys
        assertEquals(STATUS_KEYS.toSet(), keys)
    }

    @Test
    fun incompleteForeignOrEmptyOutputIsNotAStatus() {
        assertNull(parseStatus(""))
        assertNull(parseStatus(full.replace("end=1", "")))
        assertNull(parseStatus(full.replace("status-v1", "status-v2")))
        assertNull(parseStatus("sh: radio-control.sh: not found"))
    }

    @Test
    fun unknownValuesBecomeUnknownNotGuesses() {
        val s = assertNotNull(
            parseStatus(
                full.replace("hotspot_state=active", "hotspot_state=exploded")
                    .replace("hotspot_width=160", "hotspot_width=17")
                    .replace("pref_width=80", "pref_width=999")
                    .replace("six_module=present", "six_module=?")
                    .replace("wifi=1", "wifi=unknown"),
            ),
        )
        assertEquals(HotspotState.Unknown, s.hotspotState)
        assertNull(s.hotspotWidth)
        assertEquals(20, s.prefWidth)
        assertEquals(ModuleState.Unknown, s.sixModule)
        assertNull(s.wifi)
        assertFalse(s.hotspotOn)
    }

    @Test
    fun firstOccurrenceOfAKeyWins() {
        // hostapd repeats "state"; the controller's own line comes first.
        assertEquals("active", keyValues("state=active\nstate=ENABLED\n")["state"])
    }

    @Test
    fun lightStatusKeepsWhatTheLastFullStatusEstablished() {
        val first = assertNotNull(parseStatus(full))
        val lightText = full.lines().filterNot {
            it.startsWith("integrity=") || it.startsWith("identity") ||
                it.startsWith("hotspot_freq=") || it.startsWith("hotspot_channel=") ||
                it.startsWith("hotspot_status_rc=")
        }.joinToString("\n").replace("mode=full", "mode=light").replace("hotspot_checked=1", "hotspot_checked=0")
        val light = assertNotNull(parseStatus(lightText))
        assertNull(light.integrity)
        val merged = light.withKnown(first)
        assertEquals(true, merged.integrity)
        assertEquals(true, merged.identity)
        assertEquals(37, merged.hotspotChannel)
        // Another boot's reading is never carried over.
        val rebooted = assertNotNull(parseStatus(lightText.replace("boot=1", "boot=2")))
        assertNull(rebooted.withKnown(first).integrity)
        // A channel is not remembered for a hotspot that is no longer running.
        val idle = assertNotNull(parseStatus(lightText.replace("hotspot_state=active", "hotspot_state=idle")))
        assertNull(idle.withKnown(first).hotspotChannel)
    }

    @Test
    fun resultLineAndExitStatus() {
        assertEquals(OpResult(true, "none", "none", "none", 0), parseResult(listOf("phase=verify", "result=ok"), 0))
        assertEquals(
            OpResult(false, "hotspot_start", "runner_exited_during_start", "sta_band_incompatible_with_6g", 71),
            parseResult(
                listOf("result=failed step=hotspot_start reason=runner_exited_during_start detail=sta_band_incompatible_with_6g rc=71"),
                71,
            ),
        )
        // No result line: the exit status is all there is.
        assertEquals("controller_missing", parseResult(listOf("sh: not found"), 127).reason)
        assertEquals("not_root_or_wrong_context", parseResult(emptyList(), 77).reason)
        assertEquals("no_result", parseResult(emptyList(), 1).reason)
        assertTrue(parseResult(listOf("ap_key=1"), 0).ok)
        // The passphrase installer refuses with one token.
        assertEquals("key_length_invalid", parseResult(listOf("REJECT key_length_invalid"), 65).reason)
    }

    @Test
    fun passphraseRulesMatchTheInstaller() {
        assertNotNull(passphraseProblem(""))
        assertNotNull(passphraseProblem("1234567"))
        assertNull(passphraseProblem("12345678"))
        assertNull(passphraseProblem("x".repeat(63)))
        assertNotNull(passphraseProblem("x".repeat(64)))
        assertNotNull(passphraseProblem("密码密码密码密码"))
        assertNotNull(passphraseProblem("1234\t5678"))
        assertNotNull(passphraseProblem("1234\u007f5678"))
        assertNull(passphraseProblem(" a b'\"\$`\\;|&<>~"))
    }

    @Test
    fun passphraseLeavesThePageOnlyAsHex() {
        assertEquals("31323334353637383920277e", passphraseHex("123456789 '~"))
        assertFailsWith<IllegalArgumentException> { passphraseHex("short") }
        val command = Commands.setKey("it's a \$(touch x); `id` 'secret'")
        assertTrue(Regex("^echo [0-9a-f]+ \\| sh /data/adb/modules/mt6639-hotspot/bin/radio-key\\.sh /data/adb/modules/mt6639-hotspot set$").matches(command))
        assertFalse("secret" in command)
    }

    @Test
    fun onlyListedWidthsReachACommandLine() {
        assertEquals("sh /data/adb/modules/mt6639-hotspot/bin/radio-control.sh /data/adb/modules/mt6639-hotspot start 320", Commands.start(320))
        assertEquals("sh /data/adb/modules/mt6639-hotspot/bin/radio-control.sh /data/adb/modules/mt6639-hotspot set-width 40", Commands.setWidth(40))
        for (bad in listOf(0, 30, -20, 640)) {
            assertFailsWith<IllegalArgumentException> { Commands.start(bad) }
            assertFailsWith<IllegalArgumentException> { Commands.setWidth(bad) }
        }
    }

    @Test
    fun reasonsReadAsSentencesAndTheRunnerDetailWins() {
        assertTrue("2.4GHz 或 5GHz" in Messages.reason("runner_exited_during_start", "sta_band_incompatible_with_6g"))
        assertTrue("5180 MHz" in Messages.reason("sta_band_incompatible_with_6g", "upstream=wifi-any,sta_freq=5180"))
        assertFalse("{freq}" in Messages.reason("sta_band_incompatible_with_6g"))
        assertTrue("some_new_reason" in Messages.reason("some_new_reason"))
        for (reason in Messages.KNOWN_REASONS) {
            val text = Messages.reason(reason)
            assertFalse("{" in text, reason)
            assertTrue(text.endsWith("。"), reason)
        }
    }
}
