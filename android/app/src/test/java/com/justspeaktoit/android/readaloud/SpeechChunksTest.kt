package com.justspeaktoit.android.readaloud

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SpeechChunksTest {
    @Test
    fun testShortText_isOneChunk() {
        assertEquals(listOf("Hello there."), speechChunks("  Hello there. ", 100))
    }

    @Test
    fun testLongText_splitsAtSentencesThenWords_withinTheLimit() {
        val text = "One two three. Four five six seven eight nine ten."
        val chunks = speechChunks(text, 20)
        assertEquals(listOf("One two three.", "Four five six seven", "eight nine ten."), chunks)
        assertTrue(chunks.all { it.length <= 20 })
        assertEquals(text, chunks.joinToString(" "))
    }

    @Test
    fun testUnbrokenText_isCutAtTheLimit() {
        assertEquals(listOf("abcd", "efgh", "ij"), speechChunks("abcdefghij", 4))
    }

    @Test
    fun testHardCut_neverSplitsASurrogatePair() {
        val text = "a".repeat(3) + "\uD83D\uDE00" + "bc"

        assertEquals(listOf("aaa", "\uD83D\uDE00bc"), speechChunks(text, 4))
        assertEquals(listOf("\uD83D\uDE00", "b"), speechChunks("\uD83D\uDE00b", 1))
    }
}
