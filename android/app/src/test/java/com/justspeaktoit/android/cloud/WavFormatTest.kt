package com.justspeaktoit.android.cloud

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
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
}
