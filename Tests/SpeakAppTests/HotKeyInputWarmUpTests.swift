import Foundation
import XCTest

@testable import SpeakApp

/// The mic-free live-input warm-up starts on the first hotkey press and must
/// be reused by a recognised gesture or released when no start claims it (#611).
@MainActor
final class HotKeyInputWarmUpTests: XCTestCase {
    private final class FakeWarmUp {}

    private final class Environment {
        var isEligible = true
        var keepsAlive = true
        var begun: [FakeWarmUp] = []
        var released: [FakeWarmUp] = []
        let scheduler = PrimerManualScheduler()
    }

    private let doubleTapWindow: TimeInterval = 0.4
    private let lifetime: TimeInterval = 2

    private var dropDelay: TimeInterval { doubleTapWindow + HotKeyInputWarmUp<FakeWarmUp>.doubleTapGrace }

    private func makeWarmUp(_ environment: Environment) -> HotKeyInputWarmUp<FakeWarmUp> {
        HotKeyInputWarmUp(dependencies: .init(
            isEligible: { environment.isEligible },
            keepsAliveForDoubleTap: { environment.keepsAlive },
            doubleTapWindow: { [doubleTapWindow] in doubleTapWindow },
            lifetime: { [lifetime] in lifetime },
            begin: {
                let warmUp = FakeWarmUp()
                environment.begun.append(warmUp)
                return warmUp
            },
            release: { environment.released.append($0) },
            schedule: { environment.scheduler.schedule($0, $1) }
        ))
    }

    func testFirstPress_WhenEligible_StartsAWarmUp() {
        let environment = Environment()
        let warmUp = makeWarmUp(environment)

        warmUp.pressBegan(at: 10)

        XCTAssertEqual(environment.begun.count, 1)
        XCTAssertTrue(warmUp.isActive)
        XCTAssertEqual(environment.scheduler.pendingDelays, [lifetime])
    }

    func testFirstPress_WhenIneligible_StartsNothing() {
        let environment = Environment()
        environment.isEligible = false
        let warmUp = makeWarmUp(environment)

        warmUp.pressBegan(at: 10)

        XCTAssertTrue(environment.begun.isEmpty)
        XCTAssertNil(warmUp.claim())
    }

    func testConfirmedDoubleTap_ReusesTheFirstPressWarmUp() {
        let environment = Environment()
        let warmUp = makeWarmUp(environment)

        warmUp.pressBegan(at: 10)
        warmUp.pressEnded(at: 10.08)
        warmUp.pressBegan(at: 10.2)
        warmUp.pressEnded(at: 10.28)
        let claimed = warmUp.claim()

        XCTAssertEqual(environment.begun.count, 1)
        XCTAssertTrue(claimed === environment.begun.first)
        XCTAssertTrue(environment.released.isEmpty)
        XCTAssertFalse(warmUp.isActive)
        XCTAssertTrue(environment.scheduler.pendingDelays.isEmpty, "a claimed warm-up has no release timer")
    }

    func testSingleTap_ReleasesTheWarmUpAfterTheDoubleTapWindow() {
        let environment = Environment()
        let warmUp = makeWarmUp(environment)

        warmUp.pressBegan(at: 10)
        warmUp.pressEnded(at: 10.08)
        XCTAssertTrue(environment.released.isEmpty, "kept until the second tap can no longer come")
        environment.scheduler.fire(delay: dropDelay)

        XCTAssertTrue(environment.released.first === environment.begun.first)
        XCTAssertFalse(warmUp.isActive)
        XCTAssertNil(warmUp.claim(), "a single tap leaves nothing for a start to claim")
        XCTAssertTrue(environment.scheduler.pendingDelays.isEmpty)
    }

    func testUnclaimedWarmUp_IsReleasedWhenItsLifetimeExpires() {
        let environment = Environment()
        let warmUp = makeWarmUp(environment)

        warmUp.pressBegan(at: 10)
        environment.scheduler.fire(delay: lifetime)

        XCTAssertEqual(environment.released.count, 1)
        XCTAssertNil(warmUp.claim())
    }

    func testCancel_ReleasesTheWarmUpOnce() {
        let environment = Environment()
        let warmUp = makeWarmUp(environment)

        warmUp.pressBegan(at: 10)
        warmUp.cancel()
        warmUp.cancel()
        environment.scheduler.fire(delay: lifetime)

        XCTAssertEqual(environment.released.count, 1)
    }

    func testPressAfterTheDoubleTapWindow_ReplacesTheEarlierWarmUp() {
        let environment = Environment()
        let warmUp = makeWarmUp(environment)

        warmUp.pressBegan(at: 10)
        warmUp.pressEnded(at: 10.08)
        warmUp.pressBegan(at: 11)

        XCTAssertEqual(environment.begun.count, 2)
        XCTAssertTrue(environment.released.first === environment.begun.first)
        XCTAssertTrue(warmUp.claim() === environment.begun.last)
    }

    func testRelease_WhenDoubleTapIsOff_DropsAtOnce() {
        let environment = Environment()
        environment.keepsAlive = false
        let warmUp = makeWarmUp(environment)

        warmUp.pressBegan(at: 10)
        warmUp.pressEnded(at: 10.08)

        XCTAssertEqual(environment.released.count, 1)
    }

    func testHold_ClaimWhilePressed_HandsOverTheWarmUpAndReleaseLeavesItAlone() {
        let environment = Environment()
        let warmUp = makeWarmUp(environment)

        warmUp.pressBegan(at: 10)
        let claimed = warmUp.claim()
        warmUp.pressEnded(at: 12)
        environment.scheduler.fire(delay: dropDelay)
        environment.scheduler.fire(delay: lifetime)

        XCTAssertTrue(claimed === environment.begun.first)
        XCTAssertEqual(environment.begun.count, 1)
        XCTAssertTrue(environment.released.isEmpty, "the session that claimed it owns its release")
        XCTAssertTrue(environment.scheduler.pendingDelays.isEmpty)
    }

    func testRepeatedUnclaimedPresses_ReleaseEveryWarmUpExactlyOnce() {
        let environment = Environment()
        let warmUp = makeWarmUp(environment)

        for press in 0 ..< 5 {
            let start = TimeInterval(10 + press * 2)
            warmUp.pressBegan(at: start)
            warmUp.pressEnded(at: start + 0.08)
            environment.scheduler.fire(delay: dropDelay)
        }
        environment.scheduler.fire(delay: lifetime)

        XCTAssertEqual(environment.begun.count, 5)
        XCTAssertEqual(environment.released.count, 5)
        for (begun, released) in zip(environment.begun, environment.released) {
            XCTAssertTrue(begun === released)
        }
        XCTAssertFalse(warmUp.isActive)
        XCTAssertNil(warmUp.claim())
    }

    func testSecondTapAfterTheWindow_DoesNotReuseTheFirstWarmUp() {
        let environment = Environment()
        let warmUp = makeWarmUp(environment)

        warmUp.pressBegan(at: 10)
        warmUp.pressEnded(at: 10.08)
        environment.scheduler.fire(delay: dropDelay)
        warmUp.pressBegan(at: 10.6)

        XCTAssertEqual(environment.released.count, 1)
        XCTAssertTrue(warmUp.claim() === environment.begun.last)
        XCTAssertFalse(environment.begun.first === environment.begun.last)
    }

    func testStaleTimer_DoesNotReleaseANewerWarmUp() {
        let environment = Environment()
        let warmUp = makeWarmUp(environment)

        warmUp.pressBegan(at: 10)
        _ = warmUp.claim()
        warmUp.pressBegan(at: 12)
        // The first warm-up's lifetime timer was cancelled by the claim; firing
        // every lifetime timer now only expires the second one.
        environment.scheduler.fire(delay: lifetime)

        XCTAssertEqual(environment.released.count, 1)
        XCTAssertTrue(environment.released.first === environment.begun.last)
    }
}
