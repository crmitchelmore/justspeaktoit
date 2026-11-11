import XCTest

@testable import SpeakApp

#if canImport(Sentry)
import Sentry
#endif

/// Tests for SentryManager initialisation and API surface.
///
/// Critical context: SentryManager.start() runs as the VERY FIRST thing in the app
/// (in SpeakApp.init(), before any UI or service creation). The SDK now initialises
/// in both DEBUG and release builds; DEBUG disables sending via `options.enabled = false`.
/// This test file verifies:
///
/// 1. The DEBUG path (initialised but disabled) doesn't crash
/// 2. All public API methods can be called without crashing
/// 3. The breadcrumb/capture APIs handle edge cases
final class SentryManagerTests: XCTestCase {

    func testStart_doesNotCrash() {
        // DEBUG: SDK initialises with sending disabled.
        // Release (-c release): SDK initialises with production settings.
        SentryManager.start()
    }

    func testStart_canBeCalledMultipleTimes() {
        // Guard against double-init crashes. The app's init() calls start(),
        // and a developer might accidentally call it again.
        SentryManager.start()
        SentryManager.start()
    }

    func testCapture_error_doesNotCrash() {
        SentryManager.start()

        let error = NSError(domain: "test", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "Test error"
        ])
        SentryManager.capture(error: error)
    }

    func testCapture_error_withContext_doesNotCrash() {
        SentryManager.start()

        let error = NSError(domain: "test", code: 1)
        SentryManager.capture(error: error, context: [
            "key": "value",
            "number": 42
        ])
    }

    func testCapture_error_withNilContext_doesNotCrash() {
        SentryManager.start()

        let error = NSError(domain: "test", code: 0)
        SentryManager.capture(error: error, context: nil)
    }

    func testCapture_message_doesNotCrash() {
        SentryManager.start()
        SentryManager.capture(message: "Test message")
    }

    func testCapture_message_allLevels_doesNotCrash() {
        SentryManager.start()
        SentryManager.capture(message: "debug msg", level: .debug)
        SentryManager.capture(message: "info msg", level: .info)
        SentryManager.capture(message: "warning msg", level: .warning)
        SentryManager.capture(message: "error msg", level: .error)
        SentryManager.capture(message: "fatal msg", level: .fatal)
    }

    func testAddBreadcrumb_doesNotCrash() {
        SentryManager.start()
        SentryManager.addBreadcrumb(category: "test", message: "breadcrumb message")
    }

    func testAddBreadcrumb_emptyStrings_doesNotCrash() {
        SentryManager.start()
        SentryManager.addBreadcrumb(category: "", message: "")
    }

    func testSetUser_doesNotCrash() {
        SentryManager.start()
        SentryManager.setUser(id: "test-user-id")
    }

    func testSetUser_emptyID_doesNotCrash() {
        SentryManager.start()
        SentryManager.setUser(id: "")
    }

    func testStartSpan_doesNotCrash() {
        SentryManager.start()
        let span = SentryManager.startSpan(operation: "test.op", description: "Test span")
        // SDK is initialised in both modes now (disabled in DEBUG).
        // startSpan may return a span object even when disabled — that's fine,
        // the important thing is it doesn't crash.
        _ = span
    }

    // MARK: - Collection contract

        /// Mac and iOS share one configuration but report to separate projects
    /// and release packages, so their crash groups and release health never mix.
    func testDestinations_separateMacAndIOSProjectsAndReleases() {
        XCTAssertEqual(SentryManager.destination, SentryManager.macOSDestination)
        XCTAssertEqual(SentryManager.macOSDestination.releasePackage, "justspeaktoit-mac")
        XCTAssertEqual(SentryManager.iOSDestination.releasePackage, "justspeaktoit-ios")
        XCTAssertTrue(SentryManager.macOSDestination.dsn.hasSuffix("/4510790595903568"))
        XCTAssertTrue(SentryManager.iOSDestination.dsn.hasSuffix("/4510687487197264"))
        for destination in [SentryManager.macOSDestination, SentryManager.iOSDestination] {
            XCTAssertTrue(destination.dsn.hasPrefix("https://"))
            XCTAssertTrue(destination.dsn.contains(".ingest.de.sentry.io/"), "EU region only")
        }
    }

#if canImport(Sentry)
    /// The privacy-relevant options are pinned, so an SDK update cannot widen
    /// collection through a changed default. A deliberate change to the contract
    /// must change this test as well as `SentryManager.configure`.
    func testConfigure_pinsThePrivacyRelevantOptions() {
        let options = Sentry.Options()

        SentryManager.configure(options)

        XCTAssertFalse(options.sendDefaultPii, "PII must stay off")
        XCTAssertTrue(options.enableAutoSessionTracking, "Session tracking is disclosed as on")
        XCTAssertEqual(options.sessionTrackingIntervalMillis, 30_000)
        XCTAssertTrue(options.enableAutoBreadcrumbTracking)
        XCTAssertTrue(options.enableNetworkBreadcrumbs)
        XCTAssertEqual(options.maxBreadcrumbs, 100)
        XCTAssertTrue(options.enableNetworkTracking)
        XCTAssertEqual(options.tracesSampleRate?.doubleValue, 0.2)
    }

    func testConfigure_restrictsFailedRequestCaptureToTheAppsOwnHost() {
        let options = Sentry.Options()

        SentryManager.configure(options)

        XCTAssertTrue(options.enableCaptureFailedRequests)
        XCTAssertEqual(
            options.failedRequestTargets.compactMap { $0 as? String },
            ["://justspeaktoit.com"],
            "Provider responses must not be captured automatically"
        )
        let target = SentryManager.failedRequestTarget
        XCTAssertTrue("https://justspeaktoit.com/appcast.xml".contains(target))
        XCTAssertFalse("https://api.justspeaktoit.com/v1/account".contains(target), "Account routes stay out")
    }

    func testConfigure_installsTheCredentialScrubbers() {
        let options = Sentry.Options()

        SentryManager.configure(options)

        XCTAssertNotNil(options.beforeSend, "Events must pass through the scrubber")
        XCTAssertNotNil(options.beforeBreadcrumb, "Breadcrumbs must pass through the scrubber")
    }

    func testConfigure_beforeSendRedactsAProviderCredential() {
        let apiKey = "abcdefghijklmnopqrstuvwxyz012345"
        let options = Sentry.Options()
        SentryManager.configure(options)

        let request = SentryRequest()
        request.url = "https://api.elevenlabs.io/v1/speech-to-text"
        request.headers = ["xi-api-key": apiKey]
        let event = Event(level: .error)
        event.request = request

        let sent = options.beforeSend?(event)

        let serialized = String(describing: sent?.serialize() ?? [:])
        XCTAssertFalse(serialized.contains(apiKey), "beforeSend must remove the credential")
    }
    #endif
}
