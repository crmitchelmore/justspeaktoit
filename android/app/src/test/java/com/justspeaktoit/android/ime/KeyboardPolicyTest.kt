package com.justspeaktoit.android.ime

import android.text.InputType
import com.justspeaktoit.android.dictation.LanguageSupport
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.dictation.RecognizerAvailability
import com.justspeaktoit.android.dictation.RecognizerCapabilities
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyboardPolicyTest {
    private val text = InputType.TYPE_CLASS_TEXT

    @Test
    fun testPasswordFields_disableDictation() {
        assertFalse(KeyboardPolicy.allowsDictation(text or InputType.TYPE_TEXT_VARIATION_PASSWORD))
        assertFalse(KeyboardPolicy.allowsDictation(text or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD))
        assertFalse(KeyboardPolicy.allowsDictation(text or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD))
        assertFalse(
            KeyboardPolicy.allowsDictation(InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD),
        )
    }

    @Test
    fun testOrdinaryFields_allowDictation() {
        assertTrue(KeyboardPolicy.allowsDictation(text))
        assertTrue(KeyboardPolicy.allowsDictation(text or InputType.TYPE_TEXT_FLAG_MULTI_LINE))
        assertTrue(KeyboardPolicy.allowsDictation(text or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS))
        assertTrue(KeyboardPolicy.allowsDictation(InputType.TYPE_CLASS_NUMBER))
    }

    @Test
    fun testMode_neverUsesCloudAndNeverReplacesAnUnusableChoice() {
        val both = RecognizerCapabilities(34, speechServiceAvailable = true, onDeviceAvailable = true)
        val options = RecognizerAvailability.evaluate(both, LanguageSupport.Installed, cloudKeySaved = true)
        assertEquals(RecognitionMode.OnDevice, KeyboardPolicy.mode(null, options))
        assertEquals(RecognitionMode.OnDevice, KeyboardPolicy.mode(RecognitionMode.Cloud, options))
        assertEquals(RecognitionMode.SpeechService, KeyboardPolicy.mode(RecognitionMode.SpeechService, options))

        val missingModel = RecognizerAvailability.evaluate(both, LanguageSupport.Downloadable, cloudKeySaved = true)
        assertNull(KeyboardPolicy.mode(RecognitionMode.OnDevice, missingModel))
        assertEquals(RecognitionMode.SpeechService, KeyboardPolicy.mode(null, missingModel))

        val none = RecognizerCapabilities(34, speechServiceAvailable = false, onDeviceAvailable = false)
        assertNull(KeyboardPolicy.mode(null, RecognizerAvailability.evaluate(none, LanguageSupport.Unknown, true)))
    }

    @Test
    fun testSpeechService_isDisclosedUnlessExplicitlyChosen() {
        assertTrue(KeyboardPolicy.needsDisclosure(RecognitionMode.SpeechService, null))
        assertTrue(KeyboardPolicy.needsDisclosure(RecognitionMode.SpeechService, RecognitionMode.Cloud))
        assertTrue(KeyboardPolicy.needsDisclosure(RecognitionMode.SpeechService, RecognitionMode.OnDevice))
        assertFalse(KeyboardPolicy.needsDisclosure(RecognitionMode.SpeechService, RecognitionMode.SpeechService))
        assertFalse(KeyboardPolicy.needsDisclosure(RecognitionMode.OnDevice, null))
    }

    @Test
    fun testTextToCommit_addsSpaceOnlyAfterAWord() {
        assertEquals("Hello", KeyboardPolicy.textToCommit(" Hello ", null))
        assertEquals("Hello", KeyboardPolicy.textToCommit("Hello", ""))
        assertEquals(" world", KeyboardPolicy.textToCommit("world", "o"))
        assertEquals(" world", KeyboardPolicy.textToCommit("world", "."))
        assertEquals("world", KeyboardPolicy.textToCommit("world", " "))
        assertEquals("world", KeyboardPolicy.textToCommit("world", "\n"))
        assertEquals("world", KeyboardPolicy.textToCommit("world", "("))
        assertEquals("", KeyboardPolicy.textToCommit("   ", "a"))
    }
}
