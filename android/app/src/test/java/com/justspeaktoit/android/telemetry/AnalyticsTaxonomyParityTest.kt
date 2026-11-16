package com.justspeaktoit.android.telemetry

import com.justspeaktoit.android.cloud.RepoSources
import org.junit.Assert.assertTrue
import org.junit.Test

/** Android sends the Mac and iOS event names and values, so one PostHog project reads all three. */
class AnalyticsTaxonomyParityTest {
    private val events = RepoSources.speakCore("Analytics/ProductAnalyticsEvent.swift")
    private val taxonomy = RepoSources.speakCore("Analytics/ProductAnalyticsTaxonomy.swift")
    private val diagnostics = RepoSources.speakCore("Analytics/DiagnosticsConsent.swift")

    @Test
    fun testEventNames_existInSharedTaxonomy() {
        listOf(
            AnalyticsEvent.APP_ACTIVE_DAILY,
            AnalyticsEvent.ANALYTICS_OPT_IN,
            AnalyticsEvent.FIRST_TRANSCRIPTION_SUCCEEDED,
        ).forEach { assertTrue("$it missing", events.contains("\"$it\"")) }
    }

    @Test
    fun testPropertyValues_existInSharedTaxonomy() {
        val values = OptInSurface.entries.map { it.raw } + EngineType.entries.map { it.raw } +
            ProviderType.entries.map { it.raw } + DistributionChannel.entries.map { it.raw }
        values.forEach { value ->
            assertTrue(
                "$value missing",
                taxonomy.contains("\"$value\"") || Regex("""case [^\n]*\b$value\b""").containsMatchIn(taxonomy),
            )
        }
        assertTrue(Regex("""enum AnalyticsPlatform[^\n]*\b${AnalyticsContext.PLATFORM}\b""").containsMatchIn(taxonomy))
    }

    @Test
    fun testConsentRawValues_matchApple() {
        AnalyticsConsent.entries.forEach { assertTrue(Regex("""case ${it.raw}\b""").containsMatchIn(taxonomy)) }
        DiagnosticsConsent.entries.forEach { assertTrue(Regex("""case ${it.raw}\b""").containsMatchIn(diagnostics)) }
    }
}
