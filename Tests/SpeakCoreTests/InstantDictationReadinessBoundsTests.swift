import Foundation
@testable import SpeakCore
import XCTest

/// The readiness bounds for issue #995. The failure that matters here is an
/// auto-resume that never stops trying, and that is proved by driving the
/// monitor's clock rather than by holding a phone and answering calls.
final class InstantDictationReadinessBoundsTests: XCTestCase {
    private func monitor(
        window: TimeInterval = 4 * 60 * 60,
        attempts: Int = 3,
        reset: TimeInterval = 120
    ) -> InstantDictationReadinessMonitor {
        InstantDictationReadinessMonitor(
            window: window,
            maximumAttempts: attempts,
            budgetResetSeconds: reset
        )
    }

    // MARK: - Nothing happens to a healthy session

    func testHealthySessionIsLeftAlone() {
        var bounds = monitor()
        for tick in stride(from: 0.0, through: 3600, by: 30) {
            XCTAssertEqual(bounds.observe(.running, atSeconds: tick), .idle)
        }
        XCTAssertEqual(bounds.spentResumeAttempts, 0)
    }

    // MARK: - Auto-resume

    func testFirstFailureAsksForABackedOffResume() {
        var bounds = monitor()
        XCTAssertEqual(
            bounds.observe(.stopped, atSeconds: 10),
            .resume(afterSeconds: 0.5, attempt: 1)
        )
    }

    func testBackOffRises() {
        var bounds = monitor()
        XCTAssertEqual(bounds.observe(.stopped, atSeconds: 1), .resume(afterSeconds: 0.5, attempt: 1))
        bounds.noteResume(succeeded: false, atSeconds: 2)
        XCTAssertEqual(bounds.observe(.stopped, atSeconds: 3), .resume(afterSeconds: 2, attempt: 2))
        bounds.noteResume(succeeded: false, atSeconds: 4)
        XCTAssertEqual(bounds.observe(.stopped, atSeconds: 5), .resume(afterSeconds: 5, attempt: 3))
    }

    /// The loop bound: three attempts, then it stops and says why.
    func testResumeGivesUpAfterTheAttemptBudget() {
        var bounds = monitor()
        for tick in 1...3 {
            guard case .resume = bounds.observe(.stopped, atSeconds: TimeInterval(tick)) else {
                return XCTFail("attempt \(tick) should have been requested")
            }
            bounds.noteResume(succeeded: false, atSeconds: TimeInterval(tick) + 0.1)
        }
        XCTAssertEqual(bounds.observe(.stopped, atSeconds: 10), .end(.audioUnavailable))
        XCTAssertTrue(bounds.isRetired)
        XCTAssertEqual(bounds.observe(.stopped, atSeconds: 11), .idle)
    }

    /// A session that dies, comes back briefly and dies again does not get a
    /// fresh budget for the brief success. This is the case that would
    /// otherwise loop forever.
    func testShortLivedResumesDoNotRefundTheBudget() {
        var bounds = monitor()
        var clock: TimeInterval = 0
        for _ in 1...3 {
            guard case .resume = bounds.observe(.stopped, atSeconds: clock) else {
                return XCTFail("expected a resume request")
            }
            bounds.noteResume(succeeded: true, atSeconds: clock + 1)
            // Twenty seconds of health is not enough to be forgiven.
            XCTAssertEqual(bounds.observe(.running, atSeconds: clock + 10), .idle)
            XCTAssertEqual(bounds.observe(.running, atSeconds: clock + 20), .idle)
            clock += 30
        }
        XCTAssertEqual(bounds.observe(.stopped, atSeconds: clock), .end(.audioUnavailable))
    }

    /// A session that really did recover gets its attempts back.
    func testSustainedHealthForgivesTheBudget() {
        var bounds = monitor()
        XCTAssertEqual(bounds.observe(.stopped, atSeconds: 0), .resume(afterSeconds: 0.5, attempt: 1))
        bounds.noteResume(succeeded: true, atSeconds: 1)
        XCTAssertEqual(bounds.observe(.running, atSeconds: 60), .idle)
        XCTAssertEqual(bounds.spentResumeAttempts, 1)
        XCTAssertEqual(bounds.observe(.running, atSeconds: 121), .idle)
        XCTAssertEqual(bounds.spentResumeAttempts, 0)
        XCTAssertEqual(bounds.observe(.stopped, atSeconds: 122), .resume(afterSeconds: 0.5, attempt: 1))
    }

    // MARK: - Session window

    func testWindowExpiresAnIdleSession() {
        var bounds = monitor(window: 100)
        XCTAssertEqual(bounds.observe(.running, atSeconds: 99), .idle)
        XCTAssertEqual(bounds.observe(.running, atSeconds: 100), .end(.sessionWindowElapsed))
    }

    /// The window must never cut off a dictation in progress. It expires on
    /// the first tick after the dictation ends.
    func testWindowNeverExpiresMidDictation() {
        var bounds = monitor(window: 100)
        XCTAssertEqual(bounds.observe(.recording, atSeconds: 200), .idle)
        XCTAssertEqual(bounds.observe(.recording, atSeconds: 400), .idle)
        XCTAssertEqual(bounds.observe(.running, atSeconds: 401), .end(.sessionWindowElapsed))
    }

    /// A dictation in progress is health, not a stopped engine: readiness
    /// deliberately hands the microphone over for the duration.
    func testRecordingCountsAsHealth() {
        var bounds = monitor()
        XCTAssertEqual(bounds.observe(.recording, atSeconds: 5), .idle)
        XCTAssertEqual(bounds.spentResumeAttempts, 0)
    }

    // MARK: - Retirement

    func testRetiredMonitorDoesNothing() {
        var bounds = monitor(window: 10)
        bounds.retire()
        XCTAssertEqual(bounds.observe(.stopped, atSeconds: 1000), .idle)
    }

    // MARK: - Reasons

    func testEveryReasonHasAMessage() {
        let reasons: [InstantDictationReadinessEndReason] = [
            .audioUnavailable, .sessionWindowElapsed, .storeUnavailable
        ]
        for reason in reasons {
            XCTAssertFalse(reason.readinessMessage.isEmpty)
            XCTAssertEqual(InstantDictationReadinessEndReason(rawValue: reason.rawValue), reason)
        }
    }
}

/// The end reason has to survive the session it describes, and reach a
/// different process.
final class InstantDictationEndReasonStoreTests: XCTestCase {
    /// One throwaway App Group per test, torn down with it.
    private struct Harness {
        let store: KeyboardInstantDictationStore
        let defaults: UserDefaults
        let suite: String

        func tearDown() { defaults.removePersistentDomain(forName: suite) }
    }

    private func makeStore() throws -> Harness {
        let suite = "readiness.endreason.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return Harness(
            store: KeyboardInstantDictationStore(defaults: defaults),
            defaults: defaults,
            suite: suite
        )
    }

    func testReasonOutlivesTheSession() throws {
        let harness = try makeStore()
        let store = harness.store
        defer { harness.tearDown() }
        store.setEnabled(true)
        XCTAssertNotNil(store.start())
        store.end()
        store.recordEndReason(.sessionWindowElapsed)
        XCTAssertNil(store.activeSession())
        XCTAssertEqual(store.lastEndReason, .sessionWindowElapsed)
    }

    func testStartingAgainClearsAStaleReason() throws {
        let harness = try makeStore()
        let store = harness.store
        defer { harness.tearDown() }
        store.setEnabled(true)
        store.recordEndReason(.audioUnavailable)
        XCTAssertNotNil(store.start())
        XCTAssertNil(store.lastEndReason)
    }

    func testNoReasonWhenTheUserEndedIt() throws {
        let harness = try makeStore()
        let store = harness.store
        defer { harness.tearDown() }
        store.setEnabled(true)
        XCTAssertNotNil(store.start())
        store.setEnabled(false)
        XCTAssertNil(store.lastEndReason)
    }
}
