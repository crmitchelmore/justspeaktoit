package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.local.CleanupModelsState
import com.justspeaktoit.android.local.LlamaModel
import com.justspeaktoit.android.local.LocalModelItem
import com.justspeaktoit.android.local.ModelInstallState
import com.justspeaktoit.android.settings.AppPreferences
import com.justspeaktoit.android.settings.DictationProfile
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
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

    @Test
    fun testDownloadedCleanupModel_isReadyOnlyWhenDownloadedWithItsRuntime_andAProfilesCloudModelWins() {
        val model = LlamaModel(
            catalogId = SMOL, displayName = "SmolLM2", summary = "", repository = "r", revision = "v",
            url = "https://huggingface.co/r/resolve/v/m.gguf", filename = "m.gguf", bytes = 1, sha256 = "0".repeat(64),
            license = "Apache-2.0", allowedHosts = listOf("huggingface.co"), minimumDeviceMemoryBytes = null,
        )
        fun state(installState: ModelInstallState, runtime: Boolean = true) = DictationUiState(
            cleanupEnabled = true,
            localCleanup = CleanupModelsState(
                runtimeAvailable = runtime,
                models = listOf(LocalModelItem(model, installState)),
                selectedId = SMOL,
            ),
        )
        val installed = state(ModelInstallState.Installed)
        assertTrue("No cloud key is needed", installed.cleanupReady)
        assertEquals(SMOL, installed.sessionLocalCleanupModelId)
        assertFalse(state(ModelInstallState.NotDownloaded()).cleanupReady)
        assertFalse(state(ModelInstallState.Installed, runtime = false).cleanupReady)
        assertFalse(installed.copy(cleanupEnabled = false).cleanupReady)

        val cloud = CloudCatalog.cleanupModels.first()
        val profile = DictationProfile(id = "P", name = "Work", cleanupModelId = cloud.selectionId)
        val profiled = installed.copy(profile = profile)
        assertNull(profiled.sessionLocalCleanupModelId)
        assertFalse("The profile's cloud model needs its key", profiled.cleanupReady)
        assertTrue(profiled.copy(savedKeys = setOf(cloud.cloudProvider)).cleanupReady)
    }

    private companion object {
        const val SMOL = "local/post-processing/smollm2-360m-instruct-q4"
    }
}
