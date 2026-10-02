import Foundation
import SpeakCore
import XCTest

/// Synthetic, timestamped key timelines for the portable statement of the
/// macOS gesture rules. No clock, timer or keyboard is involved: every
/// deadline expiry is reported explicitly, as a host timer would.
final class HotKeyGestureMachineTests: XCTestCase {
    private typealias Gesture = HotKeyGestureMachine.Gesture

    func testHoldPastTheThreshold_startsThenReleaseEndsIt() {
        var machine = HotKeyGestureMachine()
        XCTAssertEqual(machine.keyDown(at: 10), [])
        XCTAssertEqual(machine.deadline, .init(kind: .hold, time: 10.35))
        XCTAssertEqual(machine.deadlineReached(at: 10.35), [.holdStart])
        XCTAssertTrue(machine.isHoldInProgress)
        XCTAssertNil(machine.deadline)
        XCTAssertEqual(machine.keyUp(at: 12), [.holdEnd])
        XCTAssertFalse(machine.isHoldInProgress)
        XCTAssertNil(machine.deadline)
    }

    func testRepeatedDowns_neitherRearmNorRestartTheHold() {
        var machine = HotKeyGestureMachine()
        _ = machine.keyDown(at: 1)
        XCTAssertEqual(machine.keyDown(at: 1.1), [])
        XCTAssertEqual(machine.keyDown(at: 1.3), [])
        XCTAssertEqual(machine.deadline, .init(kind: .hold, time: 1.35))
        XCTAssertEqual(machine.deadlineReached(at: 1.35), [.holdStart])
        XCTAssertEqual(machine.keyDown(at: 1.5), [])
        XCTAssertEqual(machine.keyUp(at: 1.6), [.holdEnd])
        XCTAssertEqual(machine.keyUp(at: 1.7), [], "a release without a press is ignored")
    }

    func testRapidPressAndRelease_isASingleTapAfterTheWindow() {
        var machine = HotKeyGestureMachine()
        _ = machine.keyDown(at: 5)
        XCTAssertEqual(machine.keyUp(at: 5.08), [])
        XCTAssertEqual(machine.deadline, .init(kind: .singleTap, time: 5.48))
        XCTAssertEqual(machine.deadlineReached(at: 5.48), [.singleTap])
        XCTAssertNil(machine.deadline)
    }

    func testReleaseBeforeTheThreshold_neverStartsAHold() {
        var machine = HotKeyGestureMachine()
        _ = machine.keyDown(at: 0)
        _ = machine.keyUp(at: 0.3)
        XCTAssertEqual(machine.deadlineReached(at: 0.35), [], "the hold deadline was cancelled by the release")
        XCTAssertEqual(machine.deadline?.kind, .singleTap)
    }

    func testSecondTap_isOneDoubleTapAndCancelsThePendingSingleTap() {
        var machine = HotKeyGestureMachine()
        _ = machine.keyDown(at: 2)
        _ = machine.keyUp(at: 2.1)
        _ = machine.keyDown(at: 2.25)
        XCTAssertEqual(machine.deadline?.kind, .hold, "a press replaces the pending single tap")
        XCTAssertEqual(machine.keyUp(at: 2.3), [.doubleTap])
        XCTAssertNil(machine.deadline)
        XCTAssertEqual(machine.deadlineReached(at: 2.6), [], "no single tap follows a double tap")
    }

    func testTapsJustAfterADoubleTap_areDuplicatesUntilTheGapPasses() {
        var machine = HotKeyGestureMachine()
        tap(&machine, at: 0)
        XCTAssertEqual(tap(&machine, at: 0.2), [.doubleTap])
        XCTAssertEqual(tap(&machine, at: 0.3), [], "closer than the duplicate gap")
        XCTAssertNil(machine.deadline, "a suppressed double tap arms no single tap")
        XCTAssertEqual(tap(&machine, at: 0.45), [.doubleTap], "past the gap it is a new double tap")
    }

    func testTapsSlowerThanTheWindow_areSeparateSingleTaps() {
        var machine = HotKeyGestureMachine()
        tap(&machine, at: 0)
        XCTAssertEqual(machine.deadlineReached(at: 0.45), [.singleTap])
        XCTAssertEqual(tap(&machine, at: 0.9), [])
        XCTAssertEqual(machine.deadlineReached(at: 1.35), [.singleTap])
    }

    /// The macOS detector measures a double tap from any release, so a quick
    /// tap right after ending a hold is a double tap there too.
    func testQuickTapAfterEndingAHold_isADoubleTap() {
        var machine = HotKeyGestureMachine()
        _ = machine.keyDown(at: 0)
        _ = machine.deadlineReached(at: 0.35)
        XCTAssertEqual(machine.keyUp(at: 1), [.holdEnd])
        XCTAssertEqual(tap(&machine, at: 1.2), [.doubleTap])
    }

    func testResetDuringAHold_endsItOnceAndIgnoresTheLateRelease() {
        var machine = HotKeyGestureMachine()
        _ = machine.keyDown(at: 3)
        _ = machine.deadlineReached(at: 3.35)
        XCTAssertEqual(machine.reset(), [.holdEnd])
        XCTAssertFalse(machine.isKeyDown)
        XCTAssertEqual(machine.keyUp(at: 4), [])
        XCTAssertEqual(machine.reset(), [])
    }

    func testResetBeforeTheThreshold_firesNothingAndCancelsTheDeadline() {
        var machine = HotKeyGestureMachine()
        _ = machine.keyDown(at: 0)
        XCTAssertEqual(machine.reset(), [])
        XCTAssertNil(machine.deadline)
        XCTAssertEqual(machine.deadlineReached(at: 0.35), [])
        XCTAssertEqual(machine.keyUp(at: 0.4), [])
    }

    func testResetForgetsTheLastRelease_soTheNextTapIsNotADoubleTap() {
        var machine = HotKeyGestureMachine()
        tap(&machine, at: 0)
        XCTAssertEqual(machine.reset(), [])
        XCTAssertEqual(tap(&machine, at: 0.1), [])
        XCTAssertEqual(machine.deadline?.kind, .singleTap)
    }

    func testEarlyOrStaleExpiry_isIgnoredAndTheDeadlineStaysArmed() {
        var machine = HotKeyGestureMachine()
        _ = machine.keyDown(at: 0)
        XCTAssertEqual(machine.deadlineReached(at: 0.1), [])
        XCTAssertEqual(machine.deadline, .init(kind: .hold, time: 0.35))
        XCTAssertEqual(machine.deadlineReached(at: 0.34), [.holdStart], "within the timer tolerance")
        XCTAssertEqual(machine.deadlineReached(at: 0.5), [], "a second expiry has no deadline to report")
    }

    func testFirstTapNearTimeZero_isNotADoubleTap() {
        var machine = HotKeyGestureMachine()
        XCTAssertEqual(tap(&machine, at: 0.01), [])
        XCTAssertEqual(machine.deadline?.kind, .singleTap)
    }

    func testCustomTiming_isUsedForBothDeadlines() {
        var machine = HotKeyGestureMachine(holdThreshold: 0.5, doubleTapWindow: 0.3)
        _ = machine.keyDown(at: 0)
        XCTAssertEqual(machine.deadline, .init(kind: .hold, time: 0.5))
        _ = machine.keyUp(at: 0.1)
        XCTAssertEqual(machine.deadline, .init(kind: .singleTap, time: 0.4))
        XCTAssertEqual(tap(&machine, at: 0.45), [], "0.35 s after the release exceeds a 0.3 s window")
    }

    @discardableResult
    private func tap(_ machine: inout HotKeyGestureMachine, at time: TimeInterval) -> [Gesture] {
        machine.keyDown(at: time) + machine.keyUp(at: time + 0.05)
    }
}

/// The one activation catalogue both hosts persist and filter.
final class HotKeyActivationCatalogueTests: XCTestCase {
    func testRawValues_areStablePersistedIdentities() {
        XCTAssertEqual(
            HotKeyActivationStyle.allCases.map(\.rawValue),
            ["holdToRecord", "doubleTapToggle", "holdAndDoubleTap", "pressToToggle"]
        )
    }

    func testCapabilities_matchTheMacOSSessionRules() {
        let hold = HotKeyActivationStyle.allCases.filter(\.allowsHold)
        let doubleTap = HotKeyActivationStyle.allCases.filter(\.allowsDoubleTap)
        XCTAssertEqual(hold, [.holdToRecord, .holdAndDoubleTap])
        XCTAssertEqual(doubleTap, [.doubleTapToggle, .holdAndDoubleTap])
        XCTAssertEqual(HotKeyActivationStyle.allCases.filter(\.togglesOnPress), [.pressToToggle])
    }

    func testPlatformProjections_andDefaults() {
        XCTAssertEqual(HotKeyActivationStyle.macOSStyles, [.holdToRecord, .doubleTapToggle, .holdAndDoubleTap])
        XCTAssertFalse(HotKeyActivationStyle.macOSStyles.contains(.pressToToggle))
        XCTAssertEqual(HotKeyActivationStyle.windowsStyles.first, HotKeyActivationStyle.windowsDefault)
        XCTAssertEqual(Set(HotKeyActivationStyle.windowsStyles), Set(HotKeyActivationStyle.allCases))
        XCTAssertEqual(HotKeyActivationStyle.windowsStyles.count, HotKeyActivationStyle.allCases.count)
        XCTAssertTrue(HotKeyActivationStyle.allCases.allSatisfy { !$0.summary.isEmpty })
        XCTAssertEqual(HotKeyActivationStyle.macOSDefault, .holdAndDoubleTap)
        XCTAssertEqual(HotKeyActivationStyle.windowsDefault, .pressToToggle)
        XCTAssertEqual(HotKeyActivationStyle.macOSStyles.map(\.displayName),
                       ["Press & Hold", "Double Tap", "Hold & Double Tap"])
    }

    func testTiming_matchesTheMacOSDefaults() {
        XCTAssertEqual(HotKeyGestureTiming.defaultHoldThreshold, 0.35)
        XCTAssertEqual(HotKeyGestureTiming.defaultDoubleTapWindow, 0.4)
        XCTAssertEqual(HotKeyGestureTiming.duplicateDoubleTapGap(window: 0.4), 0.2)
        XCTAssertEqual(HotKeyGestureTiming.duplicateDoubleTapGap(window: 0.8), 0.4)
        XCTAssertEqual(HotKeyGestureTiming.doubleTapCooldownCap, 0.25)
        XCTAssertEqual(HotKeyGestureTiming.doubleTapCommandInterval, 0.25)
    }
}

/// The macOS session rules every host applies to recognised gestures.
final class HotKeySessionPolicyTests: XCTestCase {
    private func command(
        _ input: HotKeySessionPolicy.Input, _ style: HotKeyActivationStyle, _ active: HotKeySessionTrigger?
    ) -> HotKeySessionCommand? {
        HotKeySessionPolicy.command(for: input, style: style, active: active)
    }

    func testHoldStartsWhenIdleAndOnlyItsReleaseStopsIt() {
        for style in [HotKeyActivationStyle.holdToRecord, .holdAndDoubleTap] {
            XCTAssertEqual(command(.gesture(.holdStart), style, nil), .start(.hold))
            XCTAssertEqual(command(.gesture(.holdEnd), style, .hold), .stop)
            for other in [HotKeySessionTrigger.doubleTap, .press, .other] {
                XCTAssertNil(command(.gesture(.holdStart), style, other), "\(style) \(other)")
                XCTAssertNil(command(.gesture(.holdEnd), style, other), "a release never ends another session")
            }
            XCTAssertNil(command(.gesture(.holdEnd), style, nil))
        }
        XCTAssertNil(command(.gesture(.holdStart), .doubleTapToggle, nil))
        XCTAssertNil(command(.gesture(.holdEnd), .doubleTapToggle, .hold))
    }

    func testDoubleTapTogglesOnlyItsOwnSessionAndSingleTapStopsIt() {
        for style in [HotKeyActivationStyle.doubleTapToggle, .holdAndDoubleTap] {
            XCTAssertEqual(command(.gesture(.doubleTap), style, nil), .start(.doubleTap))
            XCTAssertEqual(command(.gesture(.doubleTap), style, .doubleTap), .stop)
            XCTAssertEqual(command(.gesture(.singleTap), style, .doubleTap), .stop)
            XCTAssertNil(command(.gesture(.singleTap), style, nil))
            for other in [HotKeySessionTrigger.hold, .press, .other] {
                XCTAssertNil(command(.gesture(.doubleTap), style, other))
                XCTAssertNil(command(.gesture(.singleTap), style, other))
            }
        }
        XCTAssertNil(command(.gesture(.doubleTap), .holdToRecord, nil))
        XCTAssertNil(command(.gesture(.singleTap), .holdToRecord, .doubleTap))
    }

    func testPressToToggleStartsWhenIdleAndStopsAnySession() {
        XCTAssertEqual(command(.press, .pressToToggle, nil), .start(.press))
        for active in [HotKeySessionTrigger.press, .hold, .doubleTap, .other] {
            XCTAssertEqual(command(.press, .pressToToggle, active), .stop)
        }
        for style in HotKeyActivationStyle.macOSStyles {
            XCTAssertNil(command(.press, style, nil), "gesture styles classify presses instead")
        }
        for gesture in HotKeyGestureMachine.Gesture.allCases {
            XCTAssertNil(command(.gesture(gesture), .pressToToggle, nil))
            XCTAssertNil(command(.gesture(gesture), .pressToToggle, .press))
        }
    }
}
