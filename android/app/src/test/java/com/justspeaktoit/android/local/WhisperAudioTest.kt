package com.justspeaktoit.android.local

import com.justspeaktoit.android.cloud.WavFormat
import com.justspeaktoit.android.dictation.DictationFailure
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

class WhisperAudioTest {
    @get:Rule val folder = TemporaryFolder()

    private fun wav(samples: ShortArray, header: ByteArray? = null): File {
        val pcm = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        samples.forEach { pcm.putShort(it) }
        return folder.newFile().apply { writeBytes((header ?: WavFormat.header(samples.size * 2L)) + pcm.array()) }
    }

    private fun failure(file: File): DictationFailure =
        assertThrows(LocalTranscriptionException::class.java) { WhisperAudio.read(file) }.failure

    @Test
    fun testRecorderWav_isReadAsFloatSamples() {
        val samples = WhisperAudio.read(wav(shortArrayOf(0, 16_384, Short.MIN_VALUE, Short.MAX_VALUE)))
        assertArrayEquals(floatArrayOf(0f, 0.5f, -1f, 32_767f / 32_768f), samples, 0f)
    }

    @Test
    fun testMissingEmptyOrForeignAudio_failsWithoutTranscribing() {
        assertEquals(DictationFailure.Audio, failure(File(folder.root, "missing.wav")))
        assertEquals(DictationFailure.NoSpeech, failure(wav(shortArrayOf())))
        val stereo = WavFormat.header(4).also { it[22] = 2 }
        assertEquals(DictationFailure.UnsupportedAudio, failure(wav(shortArrayOf(1, 2), header = stereo)))
    }

    @Test
    fun testLanguageCode_isThePrimaryLanguageOrEmptyToDetect() {
        assertEquals("en", languageCode("en-GB"))
        assertEquals("pt", languageCode("pt-BR"))
        assertEquals("", languageCode(null))
        assertEquals("", languageCode(" "))
    }
}
