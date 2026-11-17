package com.justspeaktoit.android.history

import com.justspeaktoit.android.cloud.RepoSources
import com.justspeaktoit.android.settings.SettingsSearchAsset
import java.time.Instant
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Runs the History fixture SpeakCore's `SpeechInsightsParityTests` generates through the Android
 * engine, so the Android dashboard shows the same numbers as the Mac and iPhone for the same History.
 */
class SpeechInsightsParityTest {
    private val fixture = JSONObject(RepoSources.fixture("speech-insights/parity.json"))
    private val expected = fixture.getJSONObject("expected")
    private val definitions = SpeechInsightsDefinitions.parse(
        SettingsSearchAsset.locate("app/src/main/assets/${SpeechInsightsDefinitions.ASSET}").readText(),
    )
    private val sessions = fixture.getJSONArray("sessions").objects().map {
        SpeechSession(
            id = it.getString("id"),
            startedAtMs = Instant.parse(it.getString("startedAt")).toEpochMilli(),
            durationSeconds = it.getDouble("durationSeconds"),
            text = it.getString("text"),
        )
    }

    @Test
    fun testTokenize_matchesSpeakCoreForEverySession() {
        val tokens = expected.getJSONArray("tokens")
        sessions.forEachIndexed { index, session ->
            assertEquals(session.text, tokens.getJSONArray(index).strings(), SpeechTokenizer.tokenize(session.text))
        }
    }

    @Test
    fun testSummarize_matchesSpeakCoreNumbers() {
        val summary = SpeechInsightsEngine.summarize(sessions, definitions)

        assertEquals(expected.getInt("sessionsAnalyzed"), summary.sessionsAnalyzed)
        assertEquals(expected.getInt("totalWords"), summary.totalWords)
        assertEquals(expected.getInt("totalFillers"), summary.totalFillers)
        assertEquals(expected.getDouble("fillerRatePer1kWords"), summary.fillerRatePer1kWords, 1e-9)
        assertEquals(expected.getJSONArray("topFillers").terms(), summary.topFillers)
        assertEquals(expected.getJSONArray("topBigrams").terms(), summary.topBigrams)
        assertEquals(expected.getJSONArray("topTrigrams").terms(), summary.topTrigrams)
        assertEquals(
            expected.getJSONArray("fillerTrend").objects().map {
                Triple(it.getString("weekStart"), it.getInt("totalWords"), it.getInt("fillerCount"))
            },
            summary.fillerTrend.map { Triple(it.weekStart.toString(), it.totalWords, it.fillerCount) },
        )

        val pace = expected.getJSONObject("pace")
        assertEquals(pace.getDouble("averageWPM"), summary.pace.averageWpm, 1e-9)
        assertEquals(pace.getDouble("medianWPM"), summary.pace.medianWpm, 1e-9)
        assertEquals(pace.getInt("sessionsMeasured"), summary.pace.sessionsMeasured)
        assertEquals(
            pace.getJSONArray("distribution").objects().map { WpmBucket(it.getString("label"), it.getInt("count")) },
            summary.pace.distribution,
        )

        val longest = expected.optJSONObject("longestSession")
        if (longest == null) {
            assertNull(summary.longestSession)
        } else {
            val actual = requireNotNull(summary.longestSession)
            assertEquals(longest.getString("id"), actual.id)
            assertEquals(longest.getDouble("durationSeconds"), actual.durationSeconds, 1e-9)
            assertEquals(longest.getInt("wordCount"), actual.wordCount)
        }
    }

    @Test
    fun testUsage_matchesSpeakCoreHistoryStatistics() {
        val entries = fixture.getJSONArray("usageEntries").objects().mapIndexed { index, it ->
            HistoryEntry(
                id = "usage-$index",
                createdAtMs = 0,
                mode = "cloud",
                model = null,
                status = if (it.getBoolean("failed")) HistoryStatus.Failed else HistoryStatus.Completed,
                text = it.getString("text"),
                failure = if (it.getBoolean("failed")) "failed" else null,
                rawText = it.optString("rawText").takeIf { _ -> it.has("rawText") },
                durationSeconds = it.optDouble("durationSeconds").takeIf { _ -> it.has("durationSeconds") },
            )
        }
        val usage = UsageInsights.of(entries)
        val want = expected.getJSONObject("usage")

        assertEquals(want.getInt("sessions"), usage.sessions)
        assertEquals(want.getInt("sessionsWithErrors"), usage.sessionsWithErrors)
        assertEquals(want.getDouble("recordingSeconds"), usage.recordingSeconds, 1e-9)
        assertEquals(want.getDouble("averageSessionSeconds"), usage.averageSessionSeconds, 1e-9)
        assertEquals(want.getInt("words"), usage.words)
    }

    @Test
    fun testSessionFrom_analysesRawTextOfCompletedEntriesOnly() {
        fun entry(status: HistoryStatus, text: String, rawText: String? = null) = HistoryEntry(
            id = "id", createdAtMs = 1, mode = "cloud", model = null, status = status, text = text, rawText = rawText,
        )

        assertEquals("um ship it", SpeechSession.from(entry(HistoryStatus.Completed, "Ship it.", "um ship it"))?.text)
        assertEquals("Ship it.", SpeechSession.from(entry(HistoryStatus.Completed, "Ship it.", "  "))?.text)
        assertNull(SpeechSession.from(entry(HistoryStatus.Failed, "partial")))
        assertNull(SpeechSession.from(entry(HistoryStatus.Completed, " ")))
    }

    private fun JSONArray.objects(): List<JSONObject> = (0 until length()).map(::getJSONObject)

    private fun JSONArray.strings(): List<String> = (0 until length()).map(::getString)

    private fun JSONArray.terms(): List<TermCount> = objects().map { TermCount(it.getString("term"), it.getInt("count")) }
}
