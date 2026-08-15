import XCTest

@testable import SpeakApp

#if canImport(Sentry)
import Sentry

/// Verifies that no provider credential survives in a transmitted Sentry payload.
///
/// The check runs over the serialised event, because that is what leaves the
/// device. A smoke test of the options block cannot show this.
final class SentryEventScrubberTests: XCTestCase {

    /// A credential value long enough to be recognisable in the serialised event.
    private let apiKey = "abcdefghijklmnopqrstuvwxyz012345"

    /// Every header name the app authenticates providers with.
    private let credentialHeaders = [
        "Authorization",
        "xi-api-key",
        "x-gladia-key",
        "X-API-Key",
        "Ocp-Apim-Subscription-Key"
    ]

    // MARK: - Failed provider requests

    func testScrub_failedRequestForEveryCredentialHeader_leaksNoSecret() {
        for header in self.credentialHeaders {
            let request = SentryRequest()
            request.url = "https://api.provider.com/v1/transcribe"
            request.method = "POST"
            request.headers = [header: self.apiKey, "Content-Type": "application/json"]

            let event = Event(level: .error)
            event.request = request

            let serialized = String(describing: SentryEventScrubber.scrub(event).serialize())

            XCTAssertFalse(
                serialized.contains(self.apiKey),
                "\(header) credential must not reach Sentry"
            )
        }
    }

    func testScrub_bearerCredential_keepsSchemeOnly() {
        let request = SentryRequest()
        request.headers = ["Authorization": "Bearer \(self.apiKey)"]
        let event = Event(level: .error)
        event.request = request

        let scrubbed = SentryEventScrubber.scrub(event)

        XCTAssertEqual(scrubbed.request?.headers?["Authorization"], "Bearer [REDACTED]")
    }

    func testScrub_credentialInQueryString_isRedacted() {
        // AssemblyAI and Modulate carry the key in the URL, not a header.
        let request = SentryRequest()
        request.url = "https://www.modulate-developer-apis.com/transcribe?api_key=\(self.apiKey)"
        request.queryString = "api_key=\(self.apiKey)"
        let event = Event(level: .error)
        event.request = request

        let serialized = String(describing: SentryEventScrubber.scrub(event).serialize())

        XCTAssertFalse(serialized.contains(self.apiKey), "Query credential must not reach Sentry")
        XCTAssertTrue(serialized.contains("modulate-developer-apis.com"), "The endpoint stays diagnosable")
    }

    func testScrub_cookiesAreDropped() {
        let request = SentryRequest()
        request.cookies = "session=\(self.apiKey)"
        let event = Event(level: .error)
        event.request = request

        XCTAssertNil(SentryEventScrubber.scrub(event).request?.cookies)
    }

    // MARK: - Attached diagnostics

    func testScrub_extraAndContext_areRedacted() {
        let event = Event(level: .error)
        event.extra = ["headers": ["x-gladia-key": self.apiKey]]
        event.context = ["provider": ["api_key": self.apiKey]]

        let serialized = String(describing: SentryEventScrubber.scrub(event).serialize())

        XCTAssertFalse(serialized.contains(self.apiKey), "Attached diagnostics must not carry a credential")
    }

    func testScrub_attachedBreadcrumbs_areRedacted() {
        let crumb = Breadcrumb(level: .info, category: "http")
        crumb.data = ["url": "https://api.assemblyai.com/v2?token=\(self.apiKey)"]
        let event = Event(level: .error)
        event.breadcrumbs = [crumb]

        let serialized = String(describing: SentryEventScrubber.scrub(event).serialize())

        XCTAssertFalse(serialized.contains(self.apiKey), "Breadcrumb data must not carry a credential")
    }

    // MARK: - Breadcrumbs

    func testScrub_breadcrumbMessageWithCredentialURL_isRedacted() {
        let crumb = Breadcrumb(level: .info, category: "http")
        crumb.message = "GET https://api.assemblyai.com/v2/realtime?token=\(self.apiKey)"

        let scrubbed = SentryEventScrubber.scrub(crumb)

        XCTAssertFalse(scrubbed.message?.contains(self.apiKey) ?? false)
        XCTAssertTrue(scrubbed.message?.contains("api.assemblyai.com") ?? false)
    }

    func testScrub_breadcrumbWithoutCredentials_isUnchanged() {
        let crumb = Breadcrumb(level: .info, category: "ui")
        crumb.message = "Settings opened"
        crumb.data = ["screen": "general"]

        let scrubbed = SentryEventScrubber.scrub(crumb)

        XCTAssertEqual(scrubbed.message, "Settings opened")
        XCTAssertEqual(scrubbed.data?["screen"] as? String, "general")
    }
}
#endif
