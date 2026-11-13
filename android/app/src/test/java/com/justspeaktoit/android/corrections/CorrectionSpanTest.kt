package com.justspeaktoit.android.corrections

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

class CorrectionSpanTest {
    private val before = "Notes from Tuesday's meeting with the whole team: "
    private val after = " Thanks again, and see you all next week."
    private val context = CorrectionContext.of(before, after)
    private val span = "Hi Susie, see you soon."

    private fun window(text: String) = TextWindow(text, reachesStart = true, reachesEnd = true)

    @Test
    fun testLocate_findsTheEditedTextBetweenItsContext() {
        assertEquals(span, CorrectionSpan.locate(window("Earlier text. $before$span$after More."), context))
    }

    @Test
    fun testLocate_atTheEndsOfTheFieldNeedsTheReadToReachThem() {
        val empty = CorrectionContext.of("", "")
        assertEquals(span, CorrectionSpan.locate(window(span), empty))
        assertNull(CorrectionSpan.locate(TextWindow(span, reachesStart = false, reachesEnd = true), empty))
        assertNull(CorrectionSpan.locate(TextWindow(span, reachesStart = true, reachesEnd = false), empty))
    }

    @Test
    fun testLocate_skipsAmbiguousOrMissingContext() {
        assertNull(CorrectionSpan.locate(window("$before$span$after$before again$after"), context))
        assertNull(CorrectionSpan.locate(window("$before$span Thanks, Sam."), context))
        assertNull(CorrectionSpan.locate(window("Dear all, $span$after"), context))
    }

    @Test
    fun testLocate_skipsASpanOverTheLimit() {
        assertNull(CorrectionSpan.locate(window("$before$span$after"), context, maxLength = 10))
    }

    @Test
    fun testContext_keepsOnlyTheNearestCharacters() {
        val long = CorrectionContext.of("x".repeat(40) + "ab", "cd" + "y".repeat(40))
        assertEquals(CorrectionSpan.CONTEXT_LENGTH, long.before.length)
        assertEquals("ab", long.before.takeLast(2))
        assertEquals("cd", long.after.take(2))
        assertFalse(long.atStart || long.atEnd)
    }
}
