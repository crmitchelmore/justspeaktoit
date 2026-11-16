package com.justspeaktoit.android.diagnostics

import com.justspeaktoit.android.dictation.DictationUiState
import com.justspeaktoit.android.dictation.ModeAvailability
import com.justspeaktoit.android.dictation.ModeStatus
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.settings.DictationProfile
import com.justspeaktoit.android.settings.SettingsSearchAsset
import com.justspeaktoit.android.ui.MicPermission
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TroubleshootingTest {
    private val json = SettingsSearchAsset.locate("app/src/main/assets/${TroubleshootingRules.ASSET}").readText()
    private val rules = TroubleshootingRules.parse(json)

    private val onDeviceReady = DictationUiState(
        options = listOf(ModeAvailability(RecognitionMode.OnDevice, ModeStatus.Ready)),
        chosenMode = RecognitionMode.OnDevice,
        checkingAvailability = false,
    )

    private fun findings(
        state: DictationUiState,
        mic: MicPermission = MicPermission.Granted,
        keyboard: Boolean = true,
    ) = rules.findings(AndroidTroubleshooting.input(state, mic, keyboard))

    private fun List<TroubleshootingFinding>.of(check: TroubleshootingCheck) = firstOrNull { it.check == check }

    @Test
    fun everyExportedCheckAndFixIsKnownToAndroid() {
        val checks = JSONObject(json).getJSONArray("checks")
        for (index in 0 until checks.length()) {
            val check = checks.getJSONObject(index)
            assertTrue(check.getString("id"), TroubleshootingCheck.entries.any { it.rawValue == check.getString("id") })
            val states = check.getJSONObject("states")
            for (state in states.keys()) {
                val fixes = states.getJSONObject(state).getJSONArray("fixes")
                for (fix in 0 until fixes.length()) {
                    val raw = fixes.getString(fix)
                    assertTrue(raw, TroubleshootingFix.entries.any { it.rawValue == raw })
                }
            }
        }
    }

    @Test
    fun healthySetup_reportsEveryCheckAsReady() {
        val result = findings(onDeviceReady)

        assertEquals(
            listOf(TroubleshootingCheck.Microphone, TroubleshootingCheck.Recogniser, TroubleshootingCheck.Keyboard),
            result.map { it.check },
        )
        assertEquals(TroubleshootingSeverity.Ok, TroubleshootingRules.overall(result))
        assertTrue(result.all { it.fixes.isEmpty() })
    }

    @Test
    fun problems_sortBeforeReadyChecks() {
        val result = findings(onDeviceReady, mic = MicPermission.DeniedPermanently, keyboard = false)

        assertEquals(TroubleshootingCheck.Microphone, result.first().check)
        assertEquals(TroubleshootingSeverity.Issue, TroubleshootingRules.overall(result))
        assertEquals(TroubleshootingCheck.Recogniser, result.last().check)
    }

    @Test
    fun microphone_permanentDenialOpensAppSettingsAndFirstDenialAsksAgain() {
        val permanent = findings(onDeviceReady, mic = MicPermission.DeniedPermanently).of(TroubleshootingCheck.Microphone)
        val first = findings(onDeviceReady, mic = MicPermission.Denied).of(TroubleshootingCheck.Microphone)

        assertEquals(listOf(TroubleshootingFix.OpenSystemSettings), permanent?.fixes)
        assertEquals(listOf(TroubleshootingFix.RequestMicrophone), first?.fixes)
    }

    @Test
    fun onDeviceModelToDownload_isAWarningThatOpensTheModeChoice() {
        val state = onDeviceReady.copy(
            options = listOf(ModeAvailability(RecognitionMode.OnDevice, ModeStatus.NeedsDownload)),
        )

        val recogniser = findings(state).of(TroubleshootingCheck.Recogniser)

        assertEquals(TroubleshootingSeverity.Warning, recogniser?.severity)
        assertEquals(listOf(TroubleshootingFix.OpenTranscriptionSettings), recogniser?.fixes)
    }

    @Test
    fun recogniserNotProvided_isAnIssue() {
        val state = onDeviceReady.copy(
            options = listOf(ModeAvailability(RecognitionMode.OnDevice, ModeStatus.NotProvided)),
        )

        assertEquals(TroubleshootingSeverity.Issue, findings(state).of(TroubleshootingCheck.Recogniser)?.severity)
    }

    @Test
    fun cloudMode_checksTheKeyInsteadOfTheRecogniser() {
        val state = onDeviceReady.copy(chosenMode = RecognitionMode.Cloud)
        val provider = state.sessionCloudModel.provider

        val result = findings(state)
        val key = result.of(TroubleshootingCheck.TranscriptionKey)

        assertNull(result.of(TroubleshootingCheck.Recogniser))
        assertEquals(TroubleshootingSeverity.Issue, key?.severity)
        assertTrue(key!!.title.contains(provider.displayName))
        assertFalse(key.title.contains("{provider}"))
        assertEquals(listOf(TroubleshootingFix.OpenApiKeys, TroubleshootingFix.OpenTranscriptionSettings), key.fixes)
    }

    @Test
    fun rejectedKey_isReportedAsRejectedNotPresent() {
        val cloud = onDeviceReady.copy(chosenMode = RecognitionMode.Cloud)
        val provider = cloud.sessionCloudModel.provider
        val saved = cloud.copy(savedKeys = setOf(provider))
        val rejected = saved.copy(rejectedKeys = setOf(provider), keyErrors = setOf(provider))

        val present = findings(saved).of(TroubleshootingCheck.TranscriptionKey)
        val bad = findings(rejected).of(TroubleshootingCheck.TranscriptionKey)

        assertEquals(TroubleshootingSeverity.Ok, present?.severity)
        assertEquals(TroubleshootingSeverity.Issue, bad?.severity)
        assertNotEquals(present?.title, bad?.title)
    }

    @Test
    fun cleanupKey_isCheckedOnlyWhileCleanupIsOn() {
        val off = findings(onDeviceReady)
        val on = findings(onDeviceReady.copy(cleanupEnabled = true))

        assertNull(off.of(TroubleshootingCheck.PostProcessingKey))
        val key = on.of(TroubleshootingCheck.PostProcessingKey)
        assertTrue(key!!.title.contains(onDeviceReady.sessionCleanupModel.provider.displayName))
        assertTrue(TroubleshootingFix.DisablePostProcessing in key.fixes)
    }

    @Test
    fun turningCleanupOff_isHiddenWhileAProfileDecidesIt() {
        val user = onDeviceReady.copy(cleanupEnabled = true)
        val profiled = user.copy(profile = DictationProfile(id = "A", name = "Work", cleanupEnabled = true))
        val key = findings(user).of(TroubleshootingCheck.PostProcessingKey)!!

        assertTrue(TroubleshootingFix.DisablePostProcessing in AndroidTroubleshooting.fixes(key, user))
        assertFalse(TroubleshootingFix.DisablePostProcessing in AndroidTroubleshooting.fixes(key, profiled))
        assertTrue(TroubleshootingFix.OpenApiKeys in AndroidTroubleshooting.fixes(key, profiled))
    }

    @Test
    fun keyboardOff_offersKeyboardSetup() {
        val keyboard = findings(onDeviceReady, keyboard = false).of(TroubleshootingCheck.Keyboard)

        assertEquals(listOf(TroubleshootingFix.OpenKeyboardSetup), keyboard?.fixes)
        assertEquals(TroubleshootingSeverity.Info, keyboard?.severity)
    }
}
