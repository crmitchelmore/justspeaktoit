import XCTest

@testable import SpeakApp

/// Tests for SentryManager initialisation and API surface.
///
/// Critical context: SentryManager.start() runs as the VERY FIRST thing in the app
/// (in SpeakApp.init(), before any UI or service creation). The actual Sentry SDK
/// initialisation is gated behind `#if !DEBUG`, meaning it NEVER executes in the
/// default test configuration. This test file verifies:
///
/// 1. The debug path (no-op) doesn't crash
/// 2. All public API methods can be called without crashing
/// 3. The breadcrumb/capture APIs handle edge cases
///
/// To test the actual Sentry SDK init, run tests in release configuration:
///   swift test -c release
final class SentryManagerTests: XCTestCase {

    func testStart_doesNotCrash() {
        // This calls SentryManager.start() which in DEBUG is a no-op.
        // In release config (-c release), this actually initialises the Sentry SDK.
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
}
