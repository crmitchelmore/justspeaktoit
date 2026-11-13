package com.justspeaktoit.android.telemetry

/** Product-analytics consent. Raw values match SpeakCore's `AnalyticsConsentState`. */
enum class AnalyticsConsent(val raw: String) {
    Unknown("unknown"),
    OptedIn("optedIn"),
    OptedOut("optedOut"),
    ;

    val permitsCollection: Boolean get() = this == OptedIn

    companion object {
        fun fromRaw(raw: String?): AnalyticsConsent = entries.firstOrNull { it.raw == raw } ?: Unknown
    }
}

/** Crash-report consent. Raw values match SpeakCore's `DiagnosticsConsentDecision`. */
enum class DiagnosticsConsent(val raw: String) {
    Undecided("undecided"),
    Granted("granted"),
    Declined("declined"),
    ;

    val permitsCollection: Boolean get() = this == Granted

    companion object {
        fun fromRaw(raw: String?): DiagnosticsConsent = entries.firstOrNull { it.raw == raw } ?: Undecided
    }
}

/**
 * Telemetry choices and the analytics identity. Both consents start undecided, which collects nothing.
 * Device-local: the app opts out of Android backup and device transfer, so consent never moves devices.
 */
interface TelemetryStore {
    var analyticsConsent: AnalyticsConsent
    var diagnosticsConsent: DiagnosticsConsent

    /** A random UUID used only as PostHog's distinct ID; never shared with Sentry. Deleted on opt-out. */
    var analyticsInstallationId: String?

    /** The UTC day `app_active_daily` was last sent, as `yyyy-MM-dd`. */
    var lastActiveDay: String?

    /** The UTC day the app first ran with telemetry support, for the days-since-install bucket. */
    var firstSeenDay: String?
    var firstTranscriptionSent: Boolean
}

/** Whether the first-run consent prompt is still owed. */
val TelemetryStore.needsConsentPrompt: Boolean
    get() = analyticsConsent == AnalyticsConsent.Unknown || diagnosticsConsent == DiagnosticsConsent.Undecided
