package com.justspeaktoit.android.cloud

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

class WavFormatTest {
    @Test
    fun testHeader_describes16kMonoPcm() {
        val header = WavFormat.header(32_000)
        val le = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(44, header.size)
        assertEquals("RIFF", String(header, 0, 4))
        assertEquals(36 + 32_000, le.getInt(4))
        assertEquals("WAVEfmt ", String(header, 8, 8))
        assertEquals(1, le.getShort(20).toInt())
        assertEquals(1, le.getShort(22).toInt())
        assertEquals(16_000, le.getInt(24))
        assertEquals(32_000, le.getInt(28))
        assertEquals(2, le.getShort(32).toInt())
        assertEquals(16, le.getShort(34).toInt())
        assertEquals("data", String(header, 36, 4))
        assertEquals(32_000, le.getInt(40))
    }

    @Test
    fun testLevel_mapsSilenceAndFullScaleOntoRecognizerRange() {
        assertEquals(-2f, WavFormat.level(ShortArray(160), 160), 0.001f)
        assertEquals(10f, WavFormat.level(ShortArray(160) { Short.MAX_VALUE }, 160), 0.001f)
        val mid = WavFormat.level(ShortArray(160) { 1000 }, 160)
        assertTrue(mid > -2f && mid < 10f)
        assertEquals(-2f, WavFormat.level(ShortArray(0), 0), 0.001f)
    }

    private fun wav(samples: ShortArray): File = File.createTempFile("quiet", ".wav").apply {
        deleteOnExit()
        val pcm = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        samples.forEach { pcm.putShort(it) }
        writeBytes(WavFormat.header(pcm.capacity().toLong()) + pcm.array())
    }

    @Test
    fun testIsQuiet_treatsRoomNoiseAsSilenceButNotOneSpokenWindow() {
        assertTrue(WavFormat.isQuiet(wav(ShortArray(0))))
        assertTrue(WavFormat.isQuiet(wav(ShortArray(16_000))))
        val noise = ShortArray(16_000) { if (it % 2 == 0) 20 else -20 }
        assertTrue(WavFormat.isQuiet(wav(noise)))
        val spoken = noise.copyOf().also { for (i in 8_000 until 9_600) it[i] = if (i % 2 == 0) 3_000 else -3_000 }
        assertFalse(WavFormat.isQuiet(wav(spoken)))
    }

    @Test
    fun testIsQuiet_cannotJudgeAFileThatIsNotTheRecorderWav() {
        val other = File.createTempFile("quiet", ".m4a").apply { deleteOnExit() }
        other.writeBytes(ByteArray(4_000))
        assertFalse(WavFormat.isQuiet(other))
        other.writeBytes(ByteArray(10))
        assertFalse(WavFormat.isQuiet(other))
    }
}
