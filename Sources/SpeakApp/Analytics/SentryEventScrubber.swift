import Foundation
import SpeakCore
#if canImport(Sentry)
import Sentry
#endif

/// Removes credentials from Sentry payloads before the SDK transmits them.
///
/// The SDK sanitises a fixed list of header names (`Authorization`, `X-API-KEY`
/// and similar). The app authenticates to providers under names that list does
/// not hold — `xi-api-key`, `x-gladia-key`, `Ocp-Apim-Subscription-Key` — and two
/// providers put the key in the URL query instead of a header. A provider 5xx
/// could therefore upload a user's billable credential.
///
/// `SentryManager` installs these transforms as `beforeSend` and
/// `beforeBreadcrumb`, so every event passes through here on its way out.
///
/// Testing seam: the redaction rules are pure functions on `SpeakCore`'s
/// `SensitiveHeaderRedactor`, so they are verified without the SDK in
/// `SensitiveHeaderRedactorTests`. The adapters below only move values between
/// the SDK types and those functions.
enum SentryEventScrubber {
    #if canImport(Sentry)
    /// Redacts every credential in an event, including its request, breadcrumbs,
    /// contexts and extra data
    /// - Parameter event: The event the SDK is about to send
    /// - Returns: The same event, with credentials replaced
    static func scrub(_ event: Event) -> Event {
        if let request = event.request {
            event.request = scrub(request)
        }
        if let breadcrumbs = event.breadcrumbs {
            event.breadcrumbs = breadcrumbs.map { scrub($0) }
        }
        if let extra = event.extra {
            event.extra = SensitiveHeaderRedactor.fullyRedactSensitiveValues(in: extra)
        }
        if let context = event.context {
            var scrubbed: [String: [String: Any]] = [:]
            for (key, values) in context {
                scrubbed[key] = SensitiveHeaderRedactor.fullyRedactSensitiveValues(in: values)
            }
            event.context = scrubbed
        }
        if let tags = event.tags {
            event.tags = SensitiveHeaderRedactor.fullyRedactSensitiveHeaders(tags)
        }
        return event
    }

    /// Redacts the credential carriers of a captured HTTP request: headers,
    /// URL query, query string, fragment and cookies
    /// - Parameter request: The captured request
    /// - Returns: The same request, with credentials replaced
    static func scrub(_ request: SentryRequest) -> SentryRequest {
        if let headers = request.headers {
            request.headers = SensitiveHeaderRedactor.fullyRedactSensitiveHeaders(headers)
        }
        if let url = request.url {
            request.url = SensitiveHeaderRedactor.redactSensitiveQueryItems(in: url)
        }
        if let queryString = request.queryString {
            request.queryString = SensitiveHeaderRedactor.redactSensitiveQueryString(queryString)
        }
        if let fragment = request.fragment {
            request.fragment = SensitiveHeaderRedactor.redactSensitiveQueryString(fragment)
        }
        // Cookies carry session credentials and hold no diagnostic value here.
        request.cookies = nil
        return request
    }

    /// Redacts the credential carriers of a breadcrumb: its data map and message
    /// - Parameter crumb: The breadcrumb the SDK is about to record
    /// - Returns: The same breadcrumb, with credentials replaced
    static func scrub(_ crumb: Breadcrumb) -> Breadcrumb {
        if let data = crumb.data {
            crumb.data = SensitiveHeaderRedactor.fullyRedactSensitiveValues(in: data)
        }
        if let message = crumb.message {
            crumb.message = SensitiveHeaderRedactor.redactSensitiveQueryItems(in: message)
        }
        return crumb
    }
    #endif
}
