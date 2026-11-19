package com.justspeaktoit.android.history

import org.junit.Assert.assertEquals
import org.junit.Test

class HistoryInsightsTest {
    private val day = 24L * 60 * 60 * 1000
    private val now = 100 * day

    private fun entry(ageMs: Long, text: String, status: HistoryStatus = HistoryStatus.Completed) =
        HistoryEntry(id = "$ageMs$text", createdAtMs = now - ageMs, mode = "cloud", model = null, status = status, text = text)

    @Test
    fun testOf_countsCompletedDictationsAndWordsInTheWindow() {
        val insights = HistoryInsights.of(
            listOf(
                entry(0, " Hello  there\nworld "),
                entry(6 * day, "one"),
                entry(8 * day, "too old"),
                entry(day, "failed words", HistoryStatus.Failed),
                entry(day, "   "),
            ),
            now,
        )
        assertEquals(HistoryInsights(dictations = 2, words = 4), insights)
    }
}
