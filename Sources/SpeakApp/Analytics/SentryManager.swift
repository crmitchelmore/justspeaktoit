import CryptoKit
import Foundation
import SpeakCore
#if canImport(Sentry)
import Sentry
#endif

/// Manages Sentry crash reporting and error tracking.
///
/// The iOS app compiles this file and `SentryEventScrubber.swift` too (see
/// `Project.swift`), so both platforms share one collection contract and one
/// credential scrubber; only the destination differs.
enum SentryManager {
    /// The Sentry project and release package a platform reports to.
    struct Destination: Equatable {
        let dsn: String
        let releasePackage: String
    }

    static let macOSDestination = Destination(
        dsn: "https://6da8db9be62a737d295a727db0f6ce7e@o4510682832240640.ingest.de.sentry.io/4510790595903568",
        releasePackage: "justspeaktoit-mac"
    )

    static let iOSDestination = Destination(
        dsn: "https://0fe99ac203c91b80d4dfb0630ad7be7e@o4510682832240640.ingest.de.sentry.io/4510687487197264",
        releasePackage: "justspeaktoit-ios"
    )

    #if os(iOS)
    static let destination = iOSDestination
    #else
    static let destination = macOSDestination
    #endif

    #if canImport(Sentry)
    typealias LogLevel = SentryLevel
    typealias PerformanceSpan = Span
    #else
    enum LogLevel {
        case debug
        case info
        case warning
        case error
        case fatal
    }

    struct PerformanceSpan {}
    #endif

    /// Starts Sentry only after the user agreed to "Send crash reports and
    /// diagnostics" (`DiagnosticsConsent`); collection is off until then
    /// (App Review 5.1.1). Without consent it deletes anything an earlier
    /// version or session left behind. Call as early as possible at launch,
    /// then `observeConsent()` so later changes apply immediately.
    static func start(consent: DiagnosticsConsent = .shared) {
        guard consent.permitsCollection else {
            purgeLocalData()
            return
        }
        #if canImport(Sentry)
        guard !SentrySDK.isEnabled else { return }
        SentrySDK.start { options in
            configure(options)
            liveOptions.set(options)
        }
        #endif
    }

    /// Applies the current decision: starts reporting when granted, otherwise
    /// stops it and deletes unsent reports.
    static func applyConsent(_ consent: DiagnosticsConsent = .shared) {
        if consent.permitsCollection {
            start(consent: consent)
        } else {
            stop()
        }
    }

    /// Applies every later decision recorded in `consent`. Safe to call more
    /// than once; only the first call installs the observer.
    static func observeConsent(_ consent: DiagnosticsConsent = .shared, center: NotificationCenter = .default) {
        consentObservation.installOnce {
            center.addObserver(
                forName: DiagnosticsConsent.didChangeNotification, object: consent, queue: .main
            ) { _ in
                applyConsent(consent)
            }
        }
    }

    /// Withdrawal: stops reporting at once and deletes every report not yet sent.
    static func stop() {
        #if canImport(Sentry)
        if let options = liveOptions.take() {
            // `close()` ends the session, which writes one more envelope, then
            // flushes the transport. Disabling the live options makes the
            // client drop anything captured from here on, and deleting the
            // queue first leaves the flush nothing to send.
            options.enabled = false
            purgeLocalData()
            SentrySDK.close()
        }
        #endif
        purgeLocalData()
    }

    /// Where Sentry keeps queued envelopes, crash reports, session state and
    /// its installation ID. App-owned, so withdrawal can delete all of it: the
    /// SDK default is the Caches root, which an unsandboxed Mac shares with
    /// every other app.
    static var storage: DiagnosticsStorage {
        DiagnosticsStorage(
            caches: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory,
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.justspeaktoit",
            bundleName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        )
    }

    /// Deletes every report not yet sent. Without an explicit `storage`, unit
    /// test runs delete nothing, so they never touch a developer's real queue.
    static func purgeLocalData(_ storage: DiagnosticsStorage? = nil, fileManager: FileManager = .default) {
        guard let storage = storage ?? (NSClassFromString("XCTestCase") == nil ? Self.storage : nil) else { return }
        for url in storage.purgeTargets(dsnHash: dsnHash) where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    static var dsnHash: String? {
        #if canImport(Sentry)
        guard let url = (try? SentryDsn(string: destination.dsn))?.url else { return nil }
        // The SDK names its default queue folder with this digest (`SentryDsn.getHash()`, SPI).
        return Insecure.SHA1.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }

    private static let liveOptions = LiveOptions()
    private static let consentObservation = ConsentObservation()

    #if canImport(Sentry)
    /// Applies the app's collection contract to a fresh options object.
    ///
    /// This is separate from `start()` so a test can inspect every
    /// privacy-relevant value: a Sentry update that changes a default cannot
    /// widen collection without a diff here and a failing test.
    /// - Parameter options: The options object the SDK is about to start with
    static func configure(_ options: Sentry.Options) {
        options.dsn = destination.dsn
        options.cacheDirectoryPath = storage.directory.path
        // Set app version from bundle
        if let info = Bundle.main.infoDictionary,
           let version = info["CFBundleShortVersionString"] as? String,
           let build = info["CFBundleVersion"] as? String {
            options.releaseName = "\(destination.releasePackage)@\(version)+\(build)"
            options.dist = build
        }
        let isTestRun = NSClassFromString("XCTestCase") != nil
        #if DEBUG
        // Exercises full SDK init so linking/config issues surface in dev.
        options.enabled = false
        options.environment = "debug"
        #else
        if isTestRun {
            options.enabled = false
            options.environment = "test"
        } else {
            options.environment = ReleaseTrain.current == .alpha ? "alpha" : "production"
        }
        #endif

        // Enable performance monitoring
        options.tracesSampleRate = 0.2  // 20% of transactions

        // Attach stack traces to all events
        options.attachStacktrace = true

        // Every privacy-relevant option below is set even where the value matches
        // the current SDK default. A Sentry 9.x update must not be able to widen
        // collection through a changed default: the collection contract is what
        // this block says, and a change to it shows up as a diff here and as a
        // failure in SentryManagerTests.

        // Breadcrumbs: automatic UI and network breadcrumbs, both scrubbed by
        // `beforeBreadcrumb` below.
        options.enableAutoBreadcrumbTracking = true
        options.enableNetworkBreadcrumbs = true
        options.maxBreadcrumbs = 100

        // Sessions: release-health sessions, which carry no request or user data.
        options.enableAutoSessionTracking = true
        options.sessionTrackingIntervalMillis = 30_000

        // Network spans for performance monitoring.
        options.enableNetworkTracking = true

        // Capture HTTP client errors, but only for the app's own domain (the
        // update feed). Braces: provider traffic carries the user's billable
        // credential in a header or a query item, so no provider response is
        // captured at all. `failedRequestTargets` matches the URL by substring.
        options.enableCaptureFailedRequests = true
        options.failedRequestTargets = [Self.failedRequestTarget]

        // Belt: every event and breadcrumb, whatever its source, loses its
        // credentials before transmission. The target restriction above limits
        // what is captured; this keeps what is sent safe even if a later
        // integration captures provider traffic again.
        options.beforeSend = { event in SentryEventScrubber.scrub(event) }
        options.beforeBreadcrumb = { crumb in SentryEventScrubber.scrub(crumb) }

        // Don't send PII by default
        options.sendDefaultPii = false
    }

    /// The only host whose failed requests are captured automatically. The app
    /// sends no credential to it. The scheme separator excludes subdomains:
    /// `api.justspeaktoit.com` carries account and billing routes.
    static let failedRequestTarget = "://justspeaktoit.com"
    #endif

    /// Capture an error with optional context
    static func capture(error: Error, context: [String: Any]? = nil) {
        #if canImport(Sentry)
        SentrySDK.capture(error: error) { scope in
            if let context = context {
                scope.setContext(value: context, key: "custom")
            }
        }
        #endif
    }

    /// Capture a message for non-error events
    static func capture(message: String, level: LogLevel = .info) {
        #if canImport(Sentry)
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(level)
        }
        #else
        _ = level
        #endif
    }

    /// Add breadcrumb for debugging context
    static func addBreadcrumb(category: String, message: String, level: LogLevel = .info) {
        #if canImport(Sentry)
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
        #else
        _ = level
        #endif
    }

    /// Set user identifier (anonymized)
    static func setUser(id: String) {
        #if canImport(Sentry)
        let user = User(userId: id)
        SentrySDK.setUser(user)
        #endif
    }

    /// Start a performance transaction span
    static func startSpan(operation: String, description: String) -> PerformanceSpan? {
        #if canImport(Sentry)
        return SentrySDK.startTransaction(name: description, operation: operation)
        #else
        _ = operation
        _ = description
        return nil
        #endif
    }
}

/// Sentry's on-disk state for one app, plus the shared-default locations that
/// versions before the dedicated directory wrote to.
struct DiagnosticsStorage: Equatable {
    let caches: URL
    let bundleIdentifier: String
    let bundleName: String?

    var directory: URL {
        caches.appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Sentry", isDirectory: true)
    }

    func purgeTargets(dsnHash: String?) -> [URL] {
        var targets = [directory]
        #if os(iOS)
        // iOS Caches belongs to this app alone, so the SDK's defaults can go whole.
        targets += ["io.sentry", "SentryCrash", "INSTALLATION"].map { caches.appendingPathComponent($0) }
        #else
        // Other apps may share these roots on an unsandboxed Mac: only this
        // app's DSN queue and crash-report folder are removed.
        if let dsnHash {
            targets.append(caches.appendingPathComponent("io.sentry").appendingPathComponent(dsnHash))
        }
        if let bundleName, !bundleName.isEmpty {
            targets.append(caches.appendingPathComponent("SentryCrash").appendingPathComponent(bundleName))
        }
        #endif
        return targets
    }
}

private final class ConsentObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    func installOnce(_ install: () -> NSObjectProtocol) {
        lock.withLock {
            if token == nil { token = install() }
        }
    }
}

#if canImport(Sentry)
/// The options object the running SDK holds, so withdrawal can disable it.
private final class LiveOptions: @unchecked Sendable {
    private let lock = NSLock()
    private var options: Sentry.Options?

    func set(_ options: Sentry.Options) { lock.withLock { self.options = options } }
    func take() -> Sentry.Options? {
        lock.withLock {
            defer { options = nil }
            return options
        }
    }
}
#else
private final class LiveOptions: @unchecked Sendable {}
#endif
