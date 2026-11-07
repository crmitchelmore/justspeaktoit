package com.justspeaktoit.android.dictation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RecognizerAvailabilityTest {
    private fun status(caps: RecognizerCapabilities, language: LanguageSupport, mode: RecognitionMode) =
        RecognizerAvailability.evaluate(caps, language).single { it.mode == mode }.status

    @Test
    fun testOnDeviceBeforeAndroid12_requiresNewerAndroid() {
        val caps = RecognizerCapabilities(sdkInt = 30, speechServiceAvailable = true, onDeviceAvailable = false)
        assertEquals(ModeStatus.RequiresNewerAndroid, status(caps, LanguageSupport.Unknown, RecognitionMode.OnDevice))
        assertEquals(ModeStatus.Ready, status(caps, LanguageSupport.Unknown, RecognitionMode.SpeechService))
    }

    @Test
    fun testOnDeviceNotProvided_isReportedHonestly() {
        val caps = RecognizerCapabilities(sdkInt = 34, speechServiceAvailable = true, onDeviceAvailable = false)
        assertEquals(ModeStatus.NotProvided, status(caps, LanguageSupport.Installed, RecognitionMode.OnDevice))
    }

    @Test
    fun testOnDeviceLanguageStates_mapToStatuses() {
        val caps = RecognizerCapabilities(sdkInt = 34, speechServiceAvailable = false, onDeviceAvailable = true)
        val mode = RecognitionMode.OnDevice
        assertEquals(ModeStatus.Ready, status(caps, LanguageSupport.Installed, mode))
        assertEquals(ModeStatus.Ready, status(caps, LanguageSupport.Unknown, mode))
        assertEquals(ModeStatus.NeedsDownload, status(caps, LanguageSupport.Downloadable, mode))
        assertEquals(ModeStatus.Downloading, status(caps, LanguageSupport.Downloading, mode))
        assertEquals(ModeStatus.LanguageUnsupported, status(caps, LanguageSupport.Unsupported, mode))
        assertEquals(ModeStatus.NotProvided, status(caps, LanguageSupport.Installed, RecognitionMode.SpeechService))
    }

    @Test
    fun testDefaultMode_prefersOnDeviceThenService() {
        val both = RecognizerCapabilities(34, speechServiceAvailable = true, onDeviceAvailable = true)
        assertEquals(
            RecognitionMode.OnDevice,
            RecognizerAvailability.defaultMode(RecognizerAvailability.evaluate(both, LanguageSupport.Installed)),
        )
        assertEquals(
            RecognitionMode.SpeechService,
            RecognizerAvailability.defaultMode(RecognizerAvailability.evaluate(both, LanguageSupport.Downloadable)),
        )
    }

    @Test
    fun testCloud_needsKeyAndIsNeverTheDefault() {
        val none = RecognizerCapabilities(34, speechServiceAvailable = false, onDeviceAvailable = false)
        val withKey = RecognizerAvailability.evaluate(none, LanguageSupport.Unknown, cloudKeySaved = true)
        assertEquals(ModeStatus.Ready, withKey.single { it.mode == RecognitionMode.Cloud }.status)
        assertNull(RecognizerAvailability.defaultMode(withKey))
        val noKey = RecognizerAvailability.evaluate(none, LanguageSupport.Unknown)
        assertEquals(ModeStatus.NeedsKey, noKey.single { it.mode == RecognitionMode.Cloud }.status)
    }

    @Test
    fun testFailedLanguageCheck_isUsableButNotPreferred() {
        val both = RecognizerCapabilities(34, speechServiceAvailable = true, onDeviceAvailable = true)
        val options = RecognizerAvailability.evaluate(both, LanguageSupport.CheckFailed)
        val onDevice = options.single { it.mode == RecognitionMode.OnDevice }
        assertEquals(ModeStatus.Unverified, onDevice.status)
        assertTrue(onDevice.usable)
        assertEquals(RecognitionMode.SpeechService, RecognizerAvailability.defaultMode(options))
        val onlyOnDevice = RecognizerCapabilities(34, speechServiceAvailable = false, onDeviceAvailable = true)
        val unverifiedOnly = RecognizerAvailability.evaluate(onlyOnDevice, LanguageSupport.CheckFailed)
        assertEquals(RecognitionMode.OnDevice, RecognizerAvailability.defaultMode(unverifiedOnly))
    }

    @Test
    fun testDefaultMode_isNullWhenNothingCanRecognise() {
        val none = RecognizerCapabilities(34, speechServiceAvailable = false, onDeviceAvailable = false)
        assertNull(RecognizerAvailability.defaultMode(RecognizerAvailability.evaluate(none, LanguageSupport.Unknown)))
    }

    @Test
    fun testResolveLanguage_prefersExactTagAcrossLists() {
        val result = RecognizerAvailability.resolveLanguage(
            "en-GB",
            installed = listOf("en-US"),
            pending = emptyList(),
            supported = listOf("en-GB"),
        )
        assertEquals(LanguageResolution(LanguageSupport.Downloadable, "en-GB"), result)
    }

    @Test
    fun testResolveLanguage_fallsBackToInstalledSameLanguage() {
        val result = RecognizerAvailability.resolveLanguage("en-AU", listOf("en-US"), emptyList(), listOf("fr-FR"))
        assertEquals(LanguageResolution(LanguageSupport.Installed, "en-US"), result)
    }

    @Test
    fun testResolveLanguage_reportsPendingAndUnsupported() {
        assertEquals(
            LanguageResolution(LanguageSupport.Downloading, "de-DE"),
            RecognizerAvailability.resolveLanguage("de-DE", emptyList(), listOf("de-DE"), emptyList()),
        )
        assertEquals(
            LanguageResolution(LanguageSupport.Unsupported, "cy-GB"),
            RecognizerAvailability.resolveLanguage("cy-GB", listOf("en-US"), emptyList(), listOf("fr-FR")),
        )
    }

    @Test
    fun testResolveLanguage_isCaseInsensitive() {
        assertEquals(
            LanguageResolution(LanguageSupport.Installed, "EN-gb"),
            RecognizerAvailability.resolveLanguage("en-GB", listOf("EN-gb"), emptyList(), emptyList()),
        )
    }
}
