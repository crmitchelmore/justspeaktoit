package com.justspeaktoit.android.telemetry

import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.dictation.RecognitionMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.temporal.ChronoUnit

class ProductAnalyticsTest {
    private val store = FakeTelemetryStore()
    private val transport = RecordingTransport()
    private var now = Instant.parse("2026-07-01T10:00:00Z")
    private var ids = 0
    private val analytics = ProductAnalytics(store, testContext, transport, { now }, { "id-${++ids}" })

    @Test
    fun testUnknownConsent_sendsNothingAndCreatesNoId() {
        analytics.appBecameActive()
        analytics.transcriptionSucceeded(ProviderType.OpenAI, EngineType.Cloud)

        assertTrue(transport.sent.isEmpty())
        assertNull(store.analyticsInstallationId)
        assertFalse(store.firstTranscriptionSent)
    }

    @Test
    fun testOptedOut_sendsNothing() {
        analytics.setOptedIn(false, OptInSurface.Onboarding)
        analytics.appBecameActive()
        analytics.transcriptionSucceeded(ProviderType.Groq, EngineType.Cloud)

        assertEquals(AnalyticsConsent.OptedOut, store.analyticsConsent)
        assertTrue(transport.sent.isEmpty())
        assertNull(store.analyticsInstallationId)
    }

    @Test
    fun testOptIn_sendsOptInThenDailyActiveWithBoundedContext() {
        analytics.setOptedIn(true, OptInSurface.Onboarding)

        assertEquals(listOf("analytics_opt_in", "app_active_daily"), transport.sent.map { it.event })
        val optIn = transport.sent.first()
        assertEquals("onboarding", optIn.properties["surface"])
        assertEquals("id-1", optIn.distinctId)
        assertEquals("android", optIn.properties["platform"])
        assertEquals("google_play", optIn.properties["distribution_channel"])
        assertEquals("16.0", optIn.properties["os_major_minor"])
        assertEquals("arm64", optIn.properties["architecture"])
        assertEquals(2, optIn.properties["analytics_schema_version"])
    }

    @Test
    fun testDailyActive_sentOncePerUtcDay() {
        analytics.setOptedIn(true, OptInSurface.Settings)
        analytics.appBecameActive()
        now = now.plus(1, ChronoUnit.DAYS)
        analytics.appBecameActive()
        analytics.appBecameActive()

        assertEquals(2, transport.sent.count { it.event == "app_active_daily" })
    }

    @Test
    fun testFirstTranscription_sentOnceWithBuckets() {
        analytics.setOptedIn(true, OptInSurface.Settings)
        now = now.plus(3, ChronoUnit.DAYS)
        analytics.transcriptionSucceeded(ProviderType.Groq, EngineType.Cloud)
        analytics.transcriptionSucceeded(ProviderType.Groq, EngineType.Cloud)

        val first = transport.sent.filter { it.event == "first_transcription_succeeded" }
        assertEquals(1, first.size)
        assertEquals("groq", first.single().properties["provider_type"])
        assertEquals("cloud", first.single().properties["engine_type"])
        assertEquals("2-7", first.single().properties["days_since_install_bucket"])
    }

    @Test
    fun testOptOut_purgesAndDeletesIdentity() {
        analytics.setOptedIn(true, OptInSurface.Settings)
        analytics.setOptedIn(false, OptInSurface.Settings)
        val sentBefore = transport.sent.size
        analytics.appBecameActive()

        assertEquals(1, transport.purges)
        assertNull(store.analyticsInstallationId)
        assertNull(store.lastActiveDay)
        assertEquals(sentBefore, transport.sent.size)

        analytics.setOptedIn(true, OptInSurface.Settings)
        assertEquals("id-2", transport.sent.last().distinctId)
    }

    @Test
    fun testContext_rejectsValuesOutsideTheClosedFormats() {
        val properties = AnalyticsContext(
            appVersion = "1.0-beta+secret",
            build = "12a",
            osMajorMinor = "Baklava",
            distributionChannel = DistributionChannel.Direct,
            localeLanguageCode = "English",
            architecture = "armeabi-v7a",
        ).properties()

        assertEquals("other", properties["app_version"])
        assertEquals("other", properties["build"])
        assertEquals("other", properties["os_major_minor"])
        assertEquals("other", properties["locale_language_code"])
        assertEquals("other", properties["architecture"])
    }

    @Test
    fun testClassify_mapsModesToEngineAndProvider() {
        val groq = CloudCatalog.transcriptionModels.first { it.provider.id == "groq" }
        assertEquals(ProviderType.Groq to EngineType.Cloud, Telemetry.classify(RecognitionMode.Cloud, groq))
        assertEquals(ProviderType.Other to EngineType.OnDevice, Telemetry.classify(RecognitionMode.OnDevice, groq))
        assertEquals(ProviderType.Other to EngineType.Cloud, Telemetry.classify(RecognitionMode.SpeechService, groq))
        val assemblyAI = CloudCatalog.transcriptionModels.first { it.provider.id == "assemblyai" }
        assertEquals(ProviderType.AssemblyAI to EngineType.Cloud, Telemetry.classify(RecognitionMode.Cloud, assemblyAI))
    }

    @Test
    fun testDaysSinceInstallBuckets() {
        assertEquals(
            listOf("0", "1", "2-7", "2-7", "8-30", "8-30", ">30"),
            listOf(0L, 1, 2, 7, 8, 30, 31).map(AnalyticsEvent::daysSinceInstallBucket),
        )
    }
}
