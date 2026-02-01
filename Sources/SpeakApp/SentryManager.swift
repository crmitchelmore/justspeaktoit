import Foundation
#if canImport(Sentry)
import Sentry
#endif

/// Manages Sentry crash reporting and error tracking
enum SentryManager {
    /// Initialize Sentry SDK - call as early as possible in app lifecycle
    static func start() {
        #if DEBUG
        // Don't send errors in debug builds
        return
        #else
        #if canImport(Sentry)
        SentrySDK.start { options in
            options.dsn = "https://6da8db9be62a737d295a727db0f6ce7e@o4510682832240640.ingest.de.sentry.io/4510790595903568"
            
            // Enable performance monitoring
            options.tracesSampleRate = 0.2  // 20% of transactions
            
            // Attach stack traces to all events
            options.attachStacktrace = true
            
            // Enable automatic breadcrumbs
            options.enableAutoBreadcrumbTracking = true
            
            // Capture HTTP client errors
            options.enableCaptureFailedRequests = true
            
            // Set environment
            options.environment = "production"
            
            // Set app version from bundle
            if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
               let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                options.releaseName = "com.justspeaktoit.app@\(version)+\(build)"
            }
            
            // Don't send PII by default
            options.sendDefaultPii = false
        }
        #endif
        #endif
    }
    
    /// Capture an error with optional context
    static func capture(error: Error, context: [String: Any]? = nil) {
        #if !DEBUG
        #if canImport(Sentry)
        SentrySDK.capture(error: error) { scope in
            if let context = context {
                scope.setContext(value: context, key: "custom")
            }
        }
        #endif
        #endif
    }
    
    /// Capture a message for non-error events
    static func capture(message: String, level: SentryLevel = .info) {
        #if !DEBUG
        #if canImport(Sentry)
        SentrySDK.capture(message: message) { scope in
            scope.setLevel(level)
        }
        #endif
        #endif
    }
    
    /// Add breadcrumb for debugging context
    static func addBreadcrumb(category: String, message: String, level: SentryLevel = .info) {
        #if !DEBUG
        #if canImport(Sentry)
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
        #endif
        #endif
    }
    
    /// Set user identifier (anonymized)
    static func setUser(id: String) {
        #if !DEBUG
        #if canImport(Sentry)
        let user = User(userId: id)
        SentrySDK.setUser(user)
        #endif
        #endif
    }
    
    /// Start a performance transaction span
    static func startSpan(operation: String, description: String) -> Span? {
        #if DEBUG
        return nil
        #else
        #if canImport(Sentry)
        return SentrySDK.startTransaction(name: description, operation: operation)
        #else
        return nil
        #endif
        #endif
    }
}
