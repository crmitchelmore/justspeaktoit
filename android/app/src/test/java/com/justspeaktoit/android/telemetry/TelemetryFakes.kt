package com.justspeaktoit.android.telemetry

class FakeTelemetryStore : TelemetryStore {
    override var analyticsConsent = AnalyticsConsent.Unknown
    override var diagnosticsConsent = DiagnosticsConsent.Undecided
    override var analyticsInstallationId: String? = null
    override var lastActiveDay: String? = null
    override var firstSeenDay: String? = null
    override var firstTranscriptionSent = false
}

class RecordingTransport : AnalyticsTransport {
    val sent = mutableListOf<AnalyticsPayload>()
    var purges = 0

    override fun send(payload: AnalyticsPayload) {
        sent += payload
    }

    override fun purge() {
        purges++
    }
}

class RecordingCrashReporter : CrashReporter {
    val calls = mutableListOf<String>()

    override fun start() {
        calls += "start"
    }

    override fun stop() {
        calls += "stop"
    }
}

val testContext = AnalyticsContext(
    appVersion = "1.4.0",
    build = "212",
    osMajorMinor = "16",
    distributionChannel = DistributionChannel.GooglePlay,
    localeLanguageCode = "en",
    architecture = "arm64-v8a",
)
