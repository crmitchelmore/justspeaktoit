package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.settings.AppPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DictationUiStateTest {
    private val both = RecognizerCapabilities(34, speechServiceAvailable = true, onDeviceAvailable = true)

    @Test
    fun testKeepAudioOnCancel_defaultsOnWithTheCanonicalKey() {
        assertEquals("keepAudioOnCancel", AppPreferences.KEY_KEEP_AUDIO_ON_CANCEL)
        assertTrue(AppPreferences.DEFAULT_KEEP_AUDIO_ON_CANCEL)
        assertTrue(DictationUiState().keepAudioOnCancel)
    }

    @Test
    fun testCanStart_waitsForAvailabilityCheck() {
        val options = RecognizerAvailability.evaluate(both, LanguageSupport.Installed)
        assertFalse(DictationUiState(options = options, checkingAvailability = true).canStart)
        assertTrue(DictationUiState(options = options, checkingAvailability = false).canStart)
    }

    @Test
    fun testRunningSession_keepsItsModeWhenAvailabilityChanges() {
        val missingModel = RecognizerAvailability.evaluate(both, LanguageSupport.Downloadable)
        val running = DictationUiState(
            options = missingModel,
            checkingAvailability = false,
            dictation = DictationState.Listening(RecognitionMode.SpeechService, ""),
        )
        // The model installs mid-session: new sessions would default to on-device...
        val refreshed = running.copy(options = RecognizerAvailability.evaluate(both, LanguageSupport.Installed))
        assertEquals(RecognitionMode.OnDevice, refreshed.activeMode)
        // ...but the running session is still shown as the speech service.
        assertEquals(RecognitionMode.SpeechService, refreshed.displayedMode)
        assertEquals(RecognitionMode.SpeechService, refreshed.activeAvailability?.mode)
        assertFalse(refreshed.canStart)
    }

    @Test
    fun testExplicitUnusableChoice_disablesStartWithoutFallback() {
        val options = RecognizerAvailability.evaluate(both, LanguageSupport.Downloadable)
        val state = DictationUiState(options = options, chosenMode = RecognitionMode.OnDevice, checkingAvailability = false)
        assertEquals(RecognitionMode.OnDevice, state.activeMode)
        assertFalse(state.canStart)
    }
}
