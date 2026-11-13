import Foundation
import SpeakCore

/// What the running build reports as, resolved once at launch.
public struct DesktopTelemetryConfiguration: Sendable {
    public let context: ProductAnalyticsContext
    public let release: String
    public let environment: String
    /// Crash reports leave only release builds, so development crashes never
    /// reach the production project (as on Android and iOS).
    public let reportsCrashes: Bool
    public let postHogProjectKey: String

    public init(
        context: ProductAnalyticsContext, release: String, environment: String, reportsCrashes: Bool,
        postHogProjectKey: String
    ) {
        self.context = context
        self.release = release
        self.environment = environment
        self.reportsCrashes = reportsCrashes
        self.postHogProjectKey = postHogProjectKey
    }

    /// The PostHog project key is a public client key the Mac and Android
    /// release workflows stamp from a secret. Desktop packages do not carry it
    /// yet (#1624), so it is read from `JSTI_POSTHOG_PROJECT_KEY`; without one,
    /// analytics stays a no-op even after opting in.
    public static func current(
        platform: AnalyticsPlatform, about: DesktopAboutInformation = .current(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let release = about.configuration == "Release"
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let context = ProductAnalyticsContext(
            platform: platform, appVersion: about.version ?? "other", build: about.build ?? "other",
            osMajorMinor: "\(osVersion.majorVersion).\(osVersion.minorVersion)",
            distributionChannel: release ? .direct : .development,
            localeLanguageCode: Locale.current.identifier, architecture: architecture
        )
        let identity = about.version ?? about.commit.map { String($0.prefix(12)) } ?? "unversioned"
        return Self(
            context: context, release: "just-speak-to-it-\(platform.rawValue)@\(identity)",
            environment: release ? "production" : "development", reportsCrashes: release,
            postHogProjectKey: environment["JSTI_POSTHOG_PROJECT_KEY"] ?? ""
        )
    }
}

/// Opt-in product analytics and crash reports for Windows and Linux, with the
/// Apple and Android consent model: both start off, each is a separate
/// explicit choice in Settings, and nothing is created or sent before it.
public actor DesktopTelemetry {
    public static let sentinelName = "session-running.json"

    public nonisolated let store: DesktopTelemetryStore
    private let sentinelURL: URL
    private let now: @Sendable () -> Date
    private var configuration: DesktopTelemetryConfiguration?
    private var http: (any DesktopTelemetryHTTP)?
    private var sink: DesktopPostHogSink?
    private var analytics: ProductAnalyticsController?

    public init(directory: URL, now: @escaping @Sendable () -> Date = Date.init) {
        store = DesktopTelemetryStore(directory: directory)
        sentinelURL = directory.appendingPathComponent(Self.sentinelName)
        self.now = now
    }

    public var isActive: Bool { configuration != nil }

    /// Starts telemetry for a real app session. Smoke tests and self-tests
    /// never call this, so they leave no sentinel and send nothing.
    public func activate(_ configuration: DesktopTelemetryConfiguration, http: any DesktopTelemetryHTTP) async {
        guard self.configuration == nil else { return }
        self.configuration = configuration
        self.http = http
        let sink = DesktopPostHogSink(projectKey: configuration.postHogProjectKey, http: http, now: now)
        self.sink = sink
        analytics = try? ProductAnalyticsController(context: configuration.context, sink: sink, stateStore: store)
        if store.snapshot().firstSeenDay == nil { try? store.update { $0.firstSeenDay = day(now()) } }
        let previousSessionRunning = FileManager.default.fileExists(atPath: sentinelURL.path)
        writeSentinel()
        if previousSessionRunning { await report(.abnormalExit) }
        await appBecameActive()
    }

    /// Applies an explicit Settings choice; `nil` leaves that consent as it is.
    public func updateConsent(analytics optIn: Bool?, diagnostics grant: Bool?) async {
        if let grant { try? store.update { $0.diagnosticsConsent = grant ? .granted : .declined } }
        guard let optIn else { return }
        let wasOptedIn = store.snapshot().analyticsConsent == .optedIn
        if let analytics {
            try? await analytics.setConsent(optIn ? .optedIn : .optedOut)
        } else {
            try? store.saveConsent(optIn ? .optedIn : .optedOut)
            if !optIn { try? store.deleteInstallationID() }
        }
        guard optIn, !wasOptedIn else { return }
        await capture(.analyticsOptIn(surface: .settings))
        await appBecameActive()
    }

    /// `first_transcription_succeeded`, once per install and only while opted in.
    public func transcriptionSucceeded(provider: AnalyticsProviderType, engine: AnalyticsEngineType) async {
        let state = store.snapshot()
        guard isActive, state.analyticsConsent == .optedIn, !state.firstTranscriptionReported else { return }
        try? store.update { $0.firstTranscriptionReported = true }
        await capture(.firstTranscriptionSucceeded(
            provider: provider, engine: engine, daysSinceInstall: daysSinceInstall(state.firstSeenDay)
        ))
    }

    /// Reports an error the app could not recover from, then clears the
    /// session sentinel so the next launch does not report the same exit twice.
    public func reportFatal(_ error: Error) async {
        await report(DesktopCrashReport(error: error))
        removeSentinel()
    }

    /// A clean shutdown: the next launch must not see an abnormal exit.
    public func finishCleanly() async {
        removeSentinel()
        await sink?.close()
    }

    /// Sends one crash report when the user granted diagnostics in a release
    /// build. A failed request is dropped, never retried or kept.
    public func report(_ report: DesktopCrashReport) async {
        guard let configuration, let http, configuration.reportsCrashes,
              store.snapshot().diagnosticsConsent == .granted,
              let body = try? DesktopSentryEnvelope.body(
                report, context: configuration.context, release: configuration.release,
                environment: configuration.environment, timestamp: now()
              ) else { return }
        _ = try? await http.post(DesktopSentryEnvelope.endpoint, headers: DesktopSentryEnvelope.headers, body: body)
    }

    /// Test and shutdown hook: waits for queued analytics to be sent or dropped.
    public func flushAnalytics() async { await sink?.flush() }

    private func appBecameActive() async {
        let today = day(now())
        guard isActive, store.snapshot().analyticsConsent == .optedIn, store.snapshot().lastActiveDay != today
        else { return }
        try? store.update { $0.lastActiveDay = today }
        await capture(.appActiveDaily)
    }

    private func capture(_ event: ProductAnalyticsEvent) async {
        try? await analytics?.capture(event)
    }

    private func writeSentinel() {
        let body = ["startedAt": ISO8601DateFormatter().string(from: now())]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        try? FileManager.default.createDirectory(
            at: sentinelURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: sentinelURL, options: .atomic)
    }

    private func removeSentinel() { try? FileManager.default.removeItem(at: sentinelURL) }

    private func day(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private func daysSinceInstall(_ firstSeen: String?) -> AnalyticsDaysSinceInstallBucket {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let firstSeen, let start = formatter.date(from: firstSeen),
              let today = formatter.date(from: day(now())) else { return .zero }
        switch Int((today.timeIntervalSince(start) / 86_400).rounded()) {
        case ...0: return .zero
        case 1: return .one
        case 2...7: return .twoToSeven
        case 8...30: return .eightToThirty
        default: return .overThirty
        }
    }
}
