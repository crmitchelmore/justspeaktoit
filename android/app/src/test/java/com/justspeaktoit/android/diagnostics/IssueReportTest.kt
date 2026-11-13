package com.justspeaktoit.android.diagnostics

import com.justspeaktoit.android.dictation.DictationFailure
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryStatus
import java.net.URLDecoder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class IssueReportTest {
    private val catalogue = setOf("openai/gpt-4o-transcribe")
    private val environment = IssueEnvironment(
        architecture = "arm64",
        channel = "development",
        appVersion = "1.4.0",
        appBuild = "120",
        osVersion = "15",
        microphonePermission = "available",
    )

    private fun entry(
        model: String? = "openai/gpt-4o-transcribe",
        status: HistoryStatus = HistoryStatus.Failed,
        failure: String? = DictationFailure.TooManyRequests.name,
        text: String = "my secret dictation",
    ) = HistoryEntry(
        id = "entry-id-123",
        createdAtMs = 1_700_000_000_000,
        mode = "Cloud",
        model = model,
        status = status,
        text = text,
        failure = failure,
        audioPath = "/data/user/0/app/files/audio.m4a",
    )

    private fun report(entry: HistoryEntry = entry(), omitted: Set<IssueReport.Section> = emptySet()) =
        IssueReport.build(IssueFacts.forHistory(entry, environment, catalogue), omitted)

    @Test
    fun testBuild_neverIncludesTranscriptAudioOrIdentifiers() {
        val report = report()
        listOf("my secret dictation", "entry-id-123", "audio.m4a", "1700000000000").forEach {
            assertFalse("$it leaked", report.body.contains(it))
            assertFalse("$it leaked", report.json.contains(it))
        }
    }

    @Test
    fun testBuild_recordsCatalogueModelModeAndFailure() {
        val json = report().json
        assertTrue(json.contains("\"contextState\" : \"admission\""))
        assertTrue(json.contains("\"classification\" : \"builtIn\""))
        assertTrue(json.contains("\"identifier\" : \"openai/gpt-4o-transcribe\""))
        assertTrue(json.contains("\"mode\" : \"batch\""))
        assertTrue(json.contains("\"httpStatus\" : 429"))
        assertTrue(json.contains("\"platform\" : \"android\""))
    }

    @Test
    fun testBuild_customModelIsClassifiedWithoutItsIdentifier() {
        val json = report(entry(model = "my-private-endpoint/model")).json
        assertTrue(json.contains("\"classification\" : \"customOrUnknown\""))
        assertFalse(json.contains("my-private-endpoint"))
    }

    @Test
    fun testBuild_omittingEverySectionDropsTheContext() {
        val json = report(omitted = IssueReport.Section.entries.toSet()).json
        assertTrue(json.contains("\"contextState\" : \"userRemoved\""))
        assertTrue(json.contains("\"omissionReason\" : \"userRemoved\""))
        // The section names stay in omittedSections and the truncation counters; only their contents go.
        listOf(
            "\"context\" : {", "\"environment\" : {", "\"failures\" : [", "\"recordedModels\" : [",
            "\"timeline\" : [", "openai",
        ).forEach {
            assertFalse("$it present", json.contains(it))
        }
        assertTrue(json.contains("\"failures\" : 0"))
    }

    @Test
    fun testBuild_settingsReportHasNoContext() {
        val json = IssueReport.build(IssueFacts.forSettings(environment)).json
        assertTrue(json.contains("\"contextState\" : \"missingLegacyContext\""))
        assertFalse(json.contains("\"context\" :"))
        assertFalse(json.contains("\"omissionReason\""))
    }

    @Test
    fun testForHistory_failedEntryWithoutAReasonGetsAGenericFailure() {
        val facts = IssueFacts.forHistory(entry(failure = null), environment, catalogue)
        assertEquals(listOf(IssueFailure()), facts.failures)
        val completed = IssueFacts.forHistory(
            entry(status = HistoryStatus.Completed, failure = null),
            environment,
            catalogue,
        )
        assertTrue(completed.failures.isEmpty())
    }

    @Test
    fun testFailureOf_mapsEveryReasonToAKnownCode() {
        val codes = setOf(
            "invalidInput", "transport", "timeout", "unavailable", "permission", "authentication", "cancelled", "unknown",
        )
        DictationFailure.entries.forEach { assertTrue(it.name, IssueFailure.of(it).code in codes) }
        assertEquals("permission", IssueFailure.of(DictationFailure.PermissionDenied).code)
        assertEquals("authentication", IssueFailure.of(DictationFailure.InvalidKey).code)
    }

    @Test
    fun testNumericVersion_keepsOnlyNumericReleaseVersions() {
        assertEquals("1.4.0", IssueEnvironment.numericVersion("1.4.0"))
        assertEquals("15", IssueEnvironment.numericVersion("15"))
        assertNull(IssueEnvironment.numericVersion("1.4.0-debug"))
        assertNull(IssueEnvironment.numericVersion("1..0"))
        assertNull(IssueEnvironment.numericVersion("1.2.3.4.5"))
        assertNull(IssueEnvironment.numericVersion("123456789"))
        assertNull(IssueEnvironment.numericVersion(""))
    }

    @Test
    fun testIssueUrl_encodesTheBodyAsADraftWithTheBugLabel() {
        val report = report()
        val url = requireNotNull(report.issueUrl)
        assertTrue(url.startsWith("https://github.com/crmitchelmore/justspeaktoit/issues/new?title="))
        assertTrue(url.endsWith("&labels=bug"))
        assertFalse(url.contains("+"))
        val body = url.substringAfter("&body=").substringBefore("&labels=")
        assertEquals(report.body, URLDecoder.decode(body, "UTF-8"))
    }

    @Test
    fun testJson_sortsKeysEscapesStringsAndDropsNulls() {
        val json = IssueJson.write(
            mapOf("b" to "x\"\n\u0001", "a" to emptyList<Any>(), "c" to null, "d" to emptyMap<String, Any>()),
        )
        assertEquals("{\n  \"a\" : [],\n  \"b\" : \"x\\\"\\n\\u0001\",\n  \"d\" : {}\n}", json)
    }
}
