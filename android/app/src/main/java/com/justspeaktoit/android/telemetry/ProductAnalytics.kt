package com.justspeaktoit.android.telemetry

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.temporal.ChronoUnit
import java.util.UUID

/**
 * A product event. Names and property values come from SpeakCore's analytics taxonomy
 * (`Sources/SpeakCore/Analytics`); `AnalyticsTaxonomyParityTest` keeps them identical. Every value
 * is from a closed set, so transcripts, audio, prompts, keys or other user content cannot be sent.
 */
class AnalyticsEvent private constructor(val name: String, val properties: Map<String, String>) {
    override fun equals(other: Any?) = other is AnalyticsEvent && other.name == name && other.properties == properties

    override fun hashCode() = name.hashCode() * 31 + properties.hashCode()

    override fun toString() = "AnalyticsEvent($name, $properties)"

    companion object {
        const val APP_ACTIVE_DAILY = "app_active_daily"
        const val ANALYTICS_OPT_IN = "analytics_opt_in"
        const val FIRST_TRANSCRIPTION_SUCCEEDED = "first_transcription_succeeded"

        fun appActiveDaily() = AnalyticsEvent(APP_ACTIVE_DAILY, emptyMap())

        fun analyticsOptIn(surface: OptInSurface) = AnalyticsEvent(ANALYTICS_OPT_IN, mapOf("surface" to surface.raw))

        fun firstTranscriptionSucceeded(provider: ProviderType, engine: EngineType, daysSinceInstall: Long) =
            AnalyticsEvent(
                FIRST_TRANSCRIPTION_SUCCEEDED,
                mapOf(
                    "provider_type" to provider.raw,
                    "engine_type" to engine.raw,
                    "days_since_install_bucket" to daysSinceInstallBucket(daysSinceInstall),
                ),
            )

        /** SpeakCore's `AnalyticsDaysSinceInstallBucket`. */
        fun daysSinceInstallBucket(days: Long): String = when {
            days <= 0 -> "0"
            days == 1L -> "1"
            days <= 7 -> "2-7"
            days <= 30 -> "8-30"
            else -> ">30"
        }
    }
}

/** SpeakCore's `AnalyticsOptInSurface`. */
enum class OptInSurface(val raw: String) { Onboarding("onboarding"), Settings("settings") }

/** SpeakCore's `AnalyticsEngineType`. */
enum class EngineType(val raw: String) { OnDevice("on_device"), Cloud("cloud") }

/** The members of SpeakCore's `AnalyticsProviderType` the Android app can report. */
enum class ProviderType(val raw: String, private val providerId: String = raw) {
    OpenAI("openai"),
    Groq("groq"),
    Google("google"),
    Mistral("mistral"),
    OpenRouter("openrouter"),
    AssemblyAI("assembly_ai", "assemblyai"),
    Deepgram("deepgram"),
    ElevenLabs("eleven_labs", "elevenlabs"),
    Modulate("modulate"),
    Reson8("reson8"),
    RevAI("rev_ai", "revai"),
    Soniox("soniox"),
    Speechmatics("speechmatics"),
    Other("other"),
    ;

    companion object {
        /** The type for a catalogue provider ID; a few analytics values spell the provider differently. */
        fun forProviderId(id: String): ProviderType = entries.firstOrNull { it.providerId == id } ?: Other
    }
}

/**
 * The coarse context sent with every event: SpeakCore's `ProductAnalyticsContext`, bounded the same way so
 * nothing outside a short closed format can be sent.
 */
data class AnalyticsContext(
    val appVersion: String,
    val build: String,
    val osMajorMinor: String,
    val distributionChannel: DistributionChannel,
    val localeLanguageCode: String,
    val architecture: String,
) {
    fun properties(): Map<String, Any> = mapOf(
        "platform" to PLATFORM,
        "app_version" to boundedVersion(appVersion),
        "build" to (if (isDecimal(build, 12)) build else OTHER),
        "os_major_minor" to boundedOsVersion(osMajorMinor),
        "distribution_channel" to distributionChannel.raw,
        "locale_language_code" to boundedLanguage(localeLanguageCode),
        "architecture" to boundedArchitecture(architecture),
        "analytics_schema_version" to SCHEMA_VERSION,
    )

    companion object {
        /** SpeakCore's `AnalyticsPlatform.android`. */
        const val PLATFORM = "android"
        const val SCHEMA_VERSION = 2
        private const val OTHER = "other"

        private fun isDecimal(value: String, maxLength: Int) =
            value.isNotEmpty() && value.length <= maxLength && value.all { it in '0'..'9' }

        private fun boundedVersion(value: String): String {
            val parts = value.split('.')
            return if (parts.size in 1..4 && parts.all { isDecimal(it, 5) }) value else OTHER
        }

        /** Android reports `16` or `8.1`; both become `major.minor`. */
        private fun boundedOsVersion(value: String): String {
            val parts = value.split('.').take(2).let { if (it.size == 1) it + "0" else it }
            return if (parts.all { isDecimal(it, 3) }) parts.joinToString(".") else OTHER
        }

        private fun boundedLanguage(value: String): String {
            val language = value.lowercase().substringBefore('-').substringBefore('_')
            return if (language.length in 2..3 && language.all { it in 'a'..'z' }) language else OTHER
        }

        private fun boundedArchitecture(abi: String): String = when (abi.lowercase()) {
            "arm64-v8a", "arm64" -> "arm64"
            "x86_64" -> "x86_64"
            else -> OTHER
        }
    }
}

/** The members of SpeakCore's `AnalyticsDistributionChannel` an Android build can be. */
enum class DistributionChannel(val raw: String) {
    GooglePlay("google_play"),

    /** The Alpha APK from GitHub Releases or the website. */
    Direct("direct"),
    Development("development"),
}

/** One event ready for the wire. */
data class AnalyticsPayload(
    val event: String,
    val distinctId: String,
    val properties: Map<String, Any>,
    val timestamp: Instant,
)

/** Delivers payloads. [purge] drops everything not yet sent. */
interface AnalyticsTransport {
    fun send(payload: AnalyticsPayload)
    fun purge()
}

/**
 * Consent and identity for product analytics, mirroring the Mac's `ProductAnalyticsController`: nothing is
 * created, queued or sent unless the user opted in, and opting out purges unsent events and deletes the ID.
 */
class ProductAnalytics(
    private val store: TelemetryStore,
    private val context: AnalyticsContext,
    private val transport: AnalyticsTransport,
    private val now: () -> Instant = Instant::now,
    private val newId: () -> String = { UUID.randomUUID().toString() },
) {
    val consent: AnalyticsConsent get() = store.analyticsConsent

    init {
        if (store.firstSeenDay == null) store.firstSeenDay = today().toString()
    }

    fun setOptedIn(optedIn: Boolean, surface: OptInSurface) {
        if (optedIn) {
            val wasOptedIn = store.analyticsConsent.permitsCollection
            store.analyticsConsent = AnalyticsConsent.OptedIn
            if (!wasOptedIn) capture(AnalyticsEvent.analyticsOptIn(surface))
            appBecameActive()
        } else {
            store.analyticsConsent = AnalyticsConsent.OptedOut
            transport.purge()
            store.analyticsInstallationId = null
            store.lastActiveDay = null
        }
    }

    /** Sends `app_active_daily` at most once per UTC day. */
    fun appBecameActive() {
        if (!consent.permitsCollection) return
        val day = today().toString()
        if (store.lastActiveDay == day) return
        store.lastActiveDay = day
        capture(AnalyticsEvent.appActiveDaily())
    }

    /** Sends `first_transcription_succeeded` once per install, and only while opted in. */
    fun transcriptionSucceeded(provider: ProviderType, engine: EngineType) {
        if (!consent.permitsCollection || store.firstTranscriptionSent) return
        val firstSeen = store.firstSeenDay?.let { runCatching { LocalDate.parse(it) }.getOrNull() } ?: today()
        store.firstTranscriptionSent = true
        capture(
            AnalyticsEvent.firstTranscriptionSucceeded(provider, engine, ChronoUnit.DAYS.between(firstSeen, today())),
        )
    }

    private fun capture(event: AnalyticsEvent) {
        if (!consent.permitsCollection) return
        val id = store.analyticsInstallationId ?: newId().also { store.analyticsInstallationId = it }
        transport.send(AnalyticsPayload(event.name, id, context.properties() + event.properties, now()))
    }

    private fun today(): LocalDate = now().atZone(ZoneOffset.UTC).toLocalDate()
}
