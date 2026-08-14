import Foundation
import XCTest

@testable import SpeakApp

final class SessionTriggerTimingTests: XCTestCase {
    private let wallClock = Date(timeIntervalSince1970: 1_700_000_000)

    func testRecognisedHotKey_UsesMonotonicCaptureInterval() {
        let session = ActiveSession(
            gesture: .hold,
            hotKeyDescription: "Fn",
            triggerTiming: .recognisedHotKey(occurredAt: self.wallClock, uptime: 100)
        )
        session.captureStarted = self.wallClock.addingTimeInterval(-10)
        session.captureStartedUptime = 100.075

        XCTAssertEqual(session.captureStartMilliseconds, 75)
        XCTAssertEqual(session.buildHistoryItem(finalText: nil).latency?.captureStartMs, 75)
    }

    func testUIButtonStart_DoesNotEnterHotKeyLatencyCohort() {
        let session = ActiveSession(
            gesture: .uiButton,
            hotKeyDescription: "Fn",
            triggerTiming: .nonHotKey(occurredAt: self.wallClock)
        )
        session.captureStarted = self.wallClock.addingTimeInterval(0.1)
        session.captureStartedUptime = 100.1
        session.firstPartialReceived = self.wallClock.addingTimeInterval(0.4)

        let latency = session.buildHistoryItem(finalText: nil).latency
        XCTAssertNil(latency?.captureStartMs)
        XCTAssertEqual(latency?.firstPartialMs, 300)
    }

    func testLatencyOverview_ExcludesUIButtonSessions() {
        let hotKeySession = ActiveSession(
            gesture: .hold,
            hotKeyDescription: "Fn",
            triggerTiming: .recognisedHotKey(occurredAt: self.wallClock, uptime: 10)
        )
        hotKeySession.captureStarted = self.wallClock.addingTimeInterval(0.08)
        hotKeySession.captureStartedUptime = 10.08

        let uiSession = ActiveSession(
            gesture: .uiButton,
            hotKeyDescription: "Fn",
            triggerTiming: .nonHotKey(occurredAt: self.wallClock)
        )
        uiSession.captureStarted = self.wallClock.addingTimeInterval(4)
        uiSession.captureStartedUptime = 14

        let overview = [
            hotKeySession.buildHistoryItem(finalText: nil),
            uiSession.buildHistoryItem(finalText: nil)
        ].latencyOverview()

        XCTAssertEqual(overview.sessionCount, 1)
        XCTAssertEqual(overview.captureStartP50, 80)
        XCTAssertEqual(overview.captureStartP95, 80)
    }

    func testMonotonicClockRegression_DropsInvalidSample() {
        let timing = SessionTriggerTiming.recognisedHotKey(
            occurredAt: self.wallClock,
            uptime: 100
        )

        XCTAssertNil(timing.milliseconds(to: 99))
    }

}
