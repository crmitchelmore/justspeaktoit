package com.justspeaktoit.android.history

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId

class HistoryFilterTest {
    private val london = ZoneId.of("Europe/London")

    private fun at(text: String, zone: ZoneId = london) = LocalDateTime.parse(text).atZone(zone).toInstant().toEpochMilli()

    private fun entry(
        id: String,
        text: String = "",
        createdAtMs: Long = at("2026-11-10T12:00:00"),
        mode: String = "Cloud",
        model: String? = "openai/gpt-transcribe",
        status: HistoryStatus = HistoryStatus.Completed,
        failure: String? = null,
    ) = HistoryEntry(id, createdAtMs, mode, model, status, text, failure)

    private fun ids(filter: HistoryFilter, entries: List<HistoryEntry>, names: Map<String, String> = emptyMap()) =
        filter.matching(entries, london) { names[it] ?: it }.map { it.id }

    @Test
    fun testSearch_matchesTextModelKeyAndFriendlyNameIgnoringCaseAndSpaces() {
        val entries = listOf(
            entry("text", text = "Buy MILK tomorrow"),
            entry("key", model = "deepgram/nova-3"),
            entry("mode", mode = "OnDevice", model = null),
            entry("other", text = "unrelated"),
        )
        val names = mapOf("OnDevice" to "On this phone")
        assertEquals(listOf("text"), ids(HistoryFilter(searchText = "  milk "), entries, names))
        assertEquals(listOf("key"), ids(HistoryFilter(searchText = "NOVA"), entries, names))
        assertEquals(listOf("mode"), ids(HistoryFilter(searchText = "this phone"), entries, names))
        assertEquals(entries.map { it.id }, ids(HistoryFilter(searchText = "   "), entries, names))
    }

    @Test
    fun testModel_matchesTheCloudModelOrRecognitionModeIgnoringCase() {
        val entries = listOf(
            entry("cloud", model = "openai/gpt-transcribe"),
            entry("speech", mode = "SpeechService", model = null),
            entry("recovered", model = null),
        )
        assertEquals(listOf("openai/gpt-transcribe", "SpeechService", "Cloud"), HistoryFilter.models(entries))
        assertEquals(listOf("cloud"), ids(HistoryFilter(model = "OpenAI/GPT-Transcribe"), entries))
        assertEquals(listOf("speech"), ids(HistoryFilter(model = "SpeechService"), entries))
    }

    @Test
    fun testErrorsOnly_keepsFailedSessionsAndFailedLaterTranscriptions() {
        val entries = listOf(
            entry("ok"),
            entry("failed", status = HistoryStatus.Failed, failure = "Network"),
            entry("cancelled", status = HistoryStatus.Cancelled),
            entry("retryFailed", status = HistoryStatus.Cancelled, failure = "Network"),
        )
        assertEquals(listOf("failed", "retryFailed"), ids(HistoryFilter(errorsOnly = true), entries))
    }

    @Test
    fun testDayRange_includesWholeLocalDaysAndMirrorsTheSharedLastSecond() {
        val entries = listOf(
            entry("beforeStart", createdAtMs = at("2026-11-09T23:59:59")),
            entry("startOfDay", createdAtMs = at("2026-11-10T00:00:00")),
            entry("lastSecond", createdAtMs = at("2026-11-11T23:59:59")),
            entry("nextDay", createdAtMs = at("2026-11-12T00:00:00")),
        )
        val filter = HistoryFilter(fromDay = LocalDate.of(2026, 11, 10), throughDay = LocalDate.of(2026, 11, 11))
        assertEquals(listOf("startOfDay", "lastSecond"), ids(filter, entries))
        assertEquals(
            listOf("startOfDay", "lastSecond", "nextDay"),
            ids(HistoryFilter(fromDay = LocalDate.of(2026, 11, 10)), entries),
        )
        assertEquals(
            listOf("beforeStart", "startOfDay"),
            ids(HistoryFilter(throughDay = LocalDate.of(2026, 11, 10)), entries),
        )
    }

    @Test
    fun testNormalizedDayRange_spansDaylightSavingDaysAndUsesTheLaterDay() {
        val clocksGoBack = HistoryFilter.normalizedDayRange(
            LocalDate.of(2026, 10, 25), LocalDate.of(2026, 10, 25), london,
        )
        assertEquals(at("2026-10-25T00:00:00"), clocksGoBack.first)
        assertEquals(at("2026-10-25T23:59:59"), clocksGoBack.last)
        assertEquals(25L * 60 * 60 * 1000 - 1000, clocksGoBack.last - clocksGoBack.first)

        val reversed = HistoryFilter.normalizedDayRange(LocalDate.of(2026, 11, 12), LocalDate.of(2026, 11, 10), london)
        assertEquals(at("2026-11-12T00:00:00")..at("2026-11-12T23:59:59"), reversed)
    }

    @Test
    fun testApply_combinesConstraintsAndNeverChangesTheEntries() {
        val entries = listOf(
            entry("match", text = "meeting notes", status = HistoryStatus.Failed, failure = "Network"),
            entry("wrongModel", text = "meeting notes", model = "deepgram/nova-3", status = HistoryStatus.Failed),
            entry("noError", text = "meeting notes"),
        )
        val snapshot = entries.toList()
        val filter = HistoryFilter(searchText = "meeting", model = "openai/gpt-transcribe", errorsOnly = true)
        assertTrue(filter.isActive)
        assertEquals(listOf("match"), ids(filter, entries))
        assertEquals(snapshot, entries)
        assertFalse(HistoryFilter().isActive)
        assertEquals(entries, HistoryFilter().matching(entries, london))
    }
}
