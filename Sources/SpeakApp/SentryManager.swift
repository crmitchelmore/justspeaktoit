import Foundation
#if canImport(Sentry)
import Sentry
#endif

/// Manages Sentry crash reporting and error tracking
enum SentryManager {
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

    /// Initialize Sentry SDK - call as early as possible in app lifecycle.
    /// Runs in both DEBUG and release to verify the SDK loads and configures
    /// without crashing. DEBUG builds use a disabled DSN to avoid sending data.
    static func start() {
        #if canImport(Sentry)
        SentrySDK.start { options in configure(options) }
        #endif
    }

    #if canImport(Sentry)
    /// Applies the app's collection contract to a fresh options object.
    ///
    /// This is separate from `start()` so a test can inspect every
    /// privacy-relevant value: a Sentry update that changes a default cannot
    /// widen collection without a diff here and a failing test.
    /// - Parameter options: The options object the SDK is about to start with
    static func configure(_ options: Sentry.Options) {
        let dsn = "https://6da8db9be62a737d295a727db0f6ce7e@o4510682832240640"
            + ".ingest.de.sentry.io/4510790595903568"
        options.dsn = dsn
        // Set app version from bundle
        if let info = Bundle.main.infoDictionary,
           let version = info["CFBundleShortVersionString"] as? String,
           let build = info["CFBundleVersion"] as? String {
            options.releaseName = "justspeaktoit-mac@\(version)+\(build)"
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
            options.environment = "production"
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
    /// sends no credential to it.
    static let failedRequestTarget = "justspeaktoit.com"
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
