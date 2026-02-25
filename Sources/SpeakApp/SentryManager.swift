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
        let dsn = "https://6da8db9be62a737d295a727db0f6ce7e@o4510682832240640"
            + ".ingest.de.sentry.io/4510790595903568"
        SentrySDK.start { options in
            options.dsn = dsn
            // Set app version from bundle
            if let info = Bundle.main.infoDictionary,
               let version = info["CFBundleShortVersionString"] as? String,
               let build = info["CFBundleVersion"] as? String {
                options.releaseName = "justspeaktoit-mac@\(version)+\(build)"
                options.dist = build
            }
            #if DEBUG
            // Exercises full SDK init so linking/config issues surface in dev.
            options.enabled = false
            options.environment = "debug"
            #else
            options.environment = "production"
            #endif

            // Enable performance monitoring
            options.tracesSampleRate = 0.2  // 20% of transactions

            // Attach stack traces to all events
            options.attachStacktrace = true

            // Enable automatic breadcrumbs
            options.enableAutoBreadcrumbTracking = true

            // Capture HTTP client errors
            options.enableCaptureFailedRequests = true

            // Don't send PII by default
            options.sendDefaultPii = false
        }
        #endif
    }

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
