package com.justspeaktoit.android.cloud.live

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LivePcmTest {
    @Test
    fun testResampler_givesTheSameStreamHoweverTheInputIsSplit() {
        val input = ByteArray(6_400) { (it * 37 % 251).toByte() }.also { bytes ->
            for (i in 1 until bytes.size step 2) bytes[i] = (i / 64).toByte()
        }
        val whole = Pcm16Resampler(16_000, 24_000).process(input)
        val split = Pcm16Resampler(16_000, 24_000).let { resampler ->
            listOf(0 until 998, 998 until 3_200, 3_200 until 6_400)
                .map { resampler.process(input.copyOfRange(it.first, it.last + 1)) }
                .reduce(ByteArray::plus)
        }

        assertArrayEquals(whole, split)
        assertEquals(4_799 * 2, whole.size)
    }

    @Test
    fun testResampler_keepsAConstantLevel() {
        val out = Pcm16Resampler(16_000, 24_000).process(pcm(100, level = -1234))

        val samples = (0 until out.size / 2).map { (out[it * 2].toInt() and 0xFF) or (out[it * 2 + 1].toInt() shl 8) }
        assertTrue(samples.all { it == -1234 })
    }

    @Test
    fun testFramer_cutsWholeFramesAndPadsTheTailToTheMinimum() {
        val framer = PcmFramer(frameBytes = 3_200, minimumTailBytes = 1_600)

        assertEquals(listOf(3_200), framer.push(ByteArray(4_000)).map { it.size })
        assertEquals(listOf(1_600), framer.finish().map { it.size })
        framer.push(ByteArray(3_200 + 1_801))
        assertEquals(listOf(1_802), framer.finish().map { it.size })
        assertTrue(framer.finish().isEmpty())
    }

    @Test
    fun testDeepgramKeyterms_stayWithinTheByteBudget() {
        val words = List(200) { "term-$it-" + "x".repeat(20) }

        val terms = LiveVocabulary.deepgramKeyterms(words)

        assertTrue(terms.sumOf { it.toByteArray().size + 1 } <= 500)
        assertEquals(words.take(terms.size), terms)
    }
}
