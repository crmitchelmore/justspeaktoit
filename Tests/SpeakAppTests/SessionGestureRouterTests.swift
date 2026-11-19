import SpeakCore
import SpeakHotKeys
import XCTest

@testable import SpeakApp

@MainActor
private final class FakeGestureHandler: SessionGestureHandling {
    var hotKeyActivationStyle: AppSettings.HotKeyActivationStyle = .holdAndDoubleTap
    var activeSessionGesture: HistoryTrigger.HotKeyGesture?
    var handsFreeArmsHotKey = false
    var handsFreeConsumes = false

    var starts: [SessionTriggerSource] = []
    var ends: [SessionTriggerSource] = []
    var releasedPrimedInputs = 0
    var handsFreeToggles = 0

    func handleHandsFreeHotKey() async -> Bool {
        guard handsFreeConsumes else { return false }
        handsFreeToggles += 1
        return true
    }

    func recognisedSessionGesture(_ gesture: HotKeyGesture) -> (SessionTriggerTiming, PrimedLiveInputReservation?) {
        (.nonHotKey(), nil)
    }

    func releasePrimedInput(_ primedInput: PrimedLiveInputReservation?) {
        releasedPrimedInputs += 1
    }

    func startGestureSession(
        trigger: SessionTriggerSource,
        triggerTiming: SessionTriggerTiming,
        primedInput: PrimedLiveInputReservation?
    ) async {
        starts.append(trigger)
        activeSessionGesture = trigger.historyGesture
    }

    func endGestureSession(trigger: SessionTriggerSource) async {
        ends.append(trigger)
        activeSessionGesture = nil
    }

    func retryPostProcessing() {}
    func cancelRecordingWithEscape() {}
}

@MainActor
final class SessionGestureRouterTests: XCTestCase {
    private var handler: FakeGestureHandler!
    private var router: SessionGestureRouter!

    override func setUp() async throws {
        handler = FakeGestureHandler()
        router = SessionGestureRouter(handler: handler)
    }

    func testDoubleTap_startsThenEndsItsOwnSession() async {
        await router.handleDoubleTap(triggerTiming: .nonHotKey(), primedInput: nil, now: 10)
        await router.handleDoubleTap(triggerTiming: .nonHotKey(), primedInput: nil, now: 11)

        XCTAssertEqual(handler.starts, [.doubleTap])
        XCTAssertEqual(handler.ends, [.doubleTap])
    }

    func testDoubleTap_withinDebounceIsIgnoredAndReleasesPrimedInput() async {
        await router.handleDoubleTap(triggerTiming: .nonHotKey(), primedInput: nil, now: 10)
        await router.handleDoubleTap(
            triggerTiming: .nonHotKey(),
            primedInput: nil,
            now: 10 + SessionGestureRouter.doubleTapDebounce / 2
        )

        XCTAssertEqual(handler.starts, [.doubleTap])
        XCTAssertTrue(handler.ends.isEmpty)
        XCTAssertEqual(handler.releasedPrimedInputs, 1)
    }

    func testDoubleTap_doesNotEndAHoldSession() async {
        handler.activeSessionGesture = .hold

        await router.handleDoubleTap(triggerTiming: .nonHotKey(), primedInput: nil, now: 10)

        XCTAssertTrue(handler.ends.isEmpty)
        XCTAssertTrue(handler.starts.isEmpty)
        XCTAssertEqual(handler.releasedPrimedInputs, 1)
    }

    func testDoubleTap_armsHandsFreeInsteadOfRecording() async {
        handler.handsFreeConsumes = true

        await router.handleDoubleTap(triggerTiming: .nonHotKey(), primedInput: nil, now: 10)

        XCTAssertEqual(handler.handsFreeToggles, 1)
        XCTAssertTrue(handler.starts.isEmpty)
        XCTAssertEqual(handler.releasedPrimedInputs, 1)
    }

    func testDoubleTap_ignoredWhenStyleIsHoldOnly() async {
        handler.hotKeyActivationStyle = .holdToRecord

        await router.handleDoubleTap(triggerTiming: .nonHotKey(), primedInput: nil, now: 10)

        XCTAssertTrue(handler.starts.isEmpty)
        XCTAssertEqual(handler.releasedPrimedInputs, 1)
    }

    func testHold_startsOnPressAndEndsOnRelease() async {
        await router.handleHoldStart(triggerTiming: .nonHotKey(), primedInput: nil)
        await router.handleHoldEnd()

        XCTAssertEqual(handler.starts, [.hold])
        XCTAssertEqual(handler.ends, [.hold])
    }

    func testHoldEnd_doesNotStopAHandsFreeCapture() async {
        handler.handsFreeArmsHotKey = true
        handler.activeSessionGesture = .hold

        await router.handleHoldEnd()

        XCTAssertTrue(handler.ends.isEmpty)
    }

    func testSingleTap_endsOnlyADoubleTapSession() async {
        handler.activeSessionGesture = .hold
        await router.handleSingleTap()
        XCTAssertTrue(handler.ends.isEmpty)

        handler.activeSessionGesture = .doubleTap
        await router.handleSingleTap()
        XCTAssertEqual(handler.ends, [.singleTap])
    }
}
