import Foundation
import XCTest

@testable import SpeakApp

/// The key-down primer opens the microphone before the hold threshold and
/// must close it again for every press that does not become a session.
@MainActor
final class HotKeyPressPrimerTests: XCTestCase {

    private let doubleTapWindow: TimeInterval = 0.4
    private let safetyTimeout: TimeInterval = 10

    func makePrimer(_ environment: PrimerTestEnvironment) -> HotKeyPressPrimer<PrimerFakeCapture> {
        HotKeyPressPrimer(dependencies: .init(
            isEligible: { environment.isEligible },
            keepsAliveForDoubleTap: { environment.keepsAlive },
            doubleTapWindow: { [doubleTapWindow] in doubleTapWindow },
            safetyTimeout: { [safetyTimeout] in safetyTimeout },
            open: { keyDown in
                if environment.holdOpens {
                    await withCheckedContinuation { environment.pendingOpens.append($0) }
                }
                guard !environment.failOpen else { return nil }
                let capture = PrimerFakeCapture(keyDownUptime: keyDown)
                environment.opened.append(capture)
                return capture
            },
            close: { capture in
                capture.isClosed = true
                environment.closed.append(capture)
            },
            schedule: { environment.scheduler.schedule($0, $1) }
        ))
    }

    private var dropDelay: TimeInterval { doubleTapWindow + HotKeyPressPrimer<PrimerFakeCapture>.doubleTapGrace }

    /// Lets queued main-actor tasks run until `condition` holds.
    func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
    }

    func testPressBegan_WhenEligible_OpensTheMicrophoneWithTheKeyDownUptime() async {
        // Arrange
        let environment = PrimerTestEnvironment()
        let primer = makePrimer(environment)

        // Act
        primer.pressBegan(at: 100)
        await primer.settle()

        // Assert
        XCTAssertEqual(environment.opened.map(\.keyDownUptime), [100])
        XCTAssertTrue(primer.isActive)
        XCTAssertEqual(environment.scheduler.pendingDelays, [safetyTimeout])
    }

    func testPressBegan_WhenIneligible_OpensNothing() async {
        // Arrange
        let environment = PrimerTestEnvironment()
        environment.isEligible = false
        let primer = makePrimer(environment)

        // Act
        primer.pressBegan(at: 100)
        await primer.settle()

        // Assert
        XCTAssertTrue(environment.opened.isEmpty)
        XCTAssertFalse(primer.isActive)
        XCTAssertNil(primer.reserve())
    }

    func testReserve_AfterTheOpenFinished_HandsOverTheCaptureWithoutClosingIt() async {
        // Arrange
        let environment = PrimerTestEnvironment()
        let primer = makePrimer(environment)
        primer.pressBegan(at: 100)
        await primer.settle()

        // Act
        let reserved = await primer.reserve()?.value
        primer.pressEnded(at: 100.5)
        await primer.settle()

        // Assert
        XCTAssertTrue(reserved === environment.opened.first)
        XCTAssertTrue(environment.closed.isEmpty)
        XCTAssertFalse(primer.isActive)
        XCTAssertTrue(environment.scheduler.pendingDelays.isEmpty)
    }

    func testReserve_WhileStillOpening_HandsOverTheCaptureOnceItOpens() async {
        // Arrange
        let environment = PrimerTestEnvironment()
        environment.holdOpens = true
        let primer = makePrimer(environment)
        primer.pressBegan(at: 100)
        await waitUntil { environment.pendingOpens.count == 1 }

        // Act
        let reservation = primer.reserve()
        environment.resumeOpens()
        let reserved = await reservation?.value

        // Assert
        XCTAssertNotNil(reserved)
        XCTAssertTrue(reserved === environment.opened.first)
        XCTAssertTrue(environment.closed.isEmpty)
        XCTAssertFalse(primer.isActive)
    }

    func testReserve_WhenTheOpenFails_YieldsNil() async {
        // Arrange
        let environment = PrimerTestEnvironment()
        environment.failOpen = true
        environment.holdOpens = true
        let primer = makePrimer(environment)
        primer.pressBegan(at: 100)
        await waitUntil { environment.pendingOpens.count == 1 }

        // Act
        let reservation = primer.reserve()
        environment.resumeOpens()
        let reserved = await reservation?.value

        // Assert
        XCTAssertNil(reserved)
        XCTAssertFalse(primer.isActive)
    }

    func testPressEnded_WithoutDoubleTap_ClosesTheMicrophoneImmediately() async {
        // Arrange
        let environment = PrimerTestEnvironment()
        let primer = makePrimer(environment)
        primer.pressBegan(at: 100)
        await primer.settle()

        // Act
        primer.pressEnded(at: 100.1)
        await primer.settle()

        // Assert
        XCTAssertEqual(environment.closed.count, 1)
        XCTAssertTrue(environment.opened.first?.isClosed == true)
        XCTAssertFalse(primer.isActive)
        XCTAssertTrue(environment.scheduler.pendingDelays.isEmpty)
    }

    func testPressEnded_WhileStillOpening_ClosesTheCaptureWhenTheOpenFinishes() async {
        // Arrange
        let environment = PrimerTestEnvironment()
        environment.holdOpens = true
        let primer = makePrimer(environment)
        primer.pressBegan(at: 100)
        await waitUntil { environment.pendingOpens.count == 1 }

        // Act
        primer.pressEnded(at: 100.05)
        environment.resumeOpens()
        await primer.settle()

        // Assert
        XCTAssertEqual(environment.opened.count, 1)
        XCTAssertEqual(environment.closed.count, 1)
        XCTAssertFalse(primer.isActive)
        XCTAssertNil(primer.reserve())
    }

    func testPressEnded_WithDoubleTap_KeepsTheMicrophoneUntilTheWindowLapses() async {
        // Arrange
        let environment = PrimerTestEnvironment()
        environment.keepsAlive = true
        let primer = makePrimer(environment)
        primer.pressBegan(at: 100)
        await primer.settle()

        // Act
        primer.pressEnded(at: 100.1)
        await primer.settle()
        let closedDuringWindow = environment.closed.count
        environment.scheduler.fire(delay: dropDelay)
        await primer.settle()

        // Assert
        XCTAssertEqual(closedDuringWindow, 0)
        XCTAssertEqual(environment.closed.count, 1)
        XCTAssertFalse(primer.isActive)
    }

    func testDoubleTap_SecondPressKeepsTheFirstCaptureAndReservesIt() async {
        // Arrange
        let environment = PrimerTestEnvironment()
        environment.keepsAlive = true
        let primer = makePrimer(environment)
        primer.pressBegan(at: 100)
        await primer.settle()
        primer.pressEnded(at: 100.1)

        // Act
        primer.pressBegan(at: 100.25)
        environment.scheduler.fire(delay: dropDelay)
        primer.pressEnded(at: 100.3)
        let reserved = await primer.reserve()?.value
        await primer.settle()

        // Assert
        XCTAssertEqual(environment.opened.count, 1)
        XCTAssertTrue(reserved === environment.opened.first)
        XCTAssertTrue(environment.closed.isEmpty)
        XCTAssertEqual(primer.sequenceKeyDownUptime, 100)
    }

    func testSequenceKeyDownUptime_StartsANewSequenceAfterTheDoubleTapWindow() {
        // Arrange
        let environment = PrimerTestEnvironment()
        environment.isEligible = false
        let primer = makePrimer(environment)
        primer.pressBegan(at: 100)
        primer.pressEnded(at: 100.1)

        // Act
        primer.pressBegan(at: 101)

        // Assert
        XCTAssertEqual(primer.sequenceKeyDownUptime, 101)
    }

    func testSafetyTimeout_ClosesAHeldMicrophoneNoSessionClaimed() async {
        // Arrange
        let environment = PrimerTestEnvironment()
        let primer = makePrimer(environment)
        primer.pressBegan(at: 100)
        await primer.settle()

        // Act
        environment.scheduler.fire(delay: safetyTimeout)
        await primer.settle()

        // Assert
        XCTAssertEqual(environment.closed.count, 1)
        XCTAssertFalse(primer.isActive)
    }

    func testCancel_ClosesAnUnclaimedMicrophone() async {
        // Arrange
        let environment = PrimerTestEnvironment()
        let primer = makePrimer(environment)
        primer.pressBegan(at: 100)
        await primer.settle()

        // Act
        primer.cancel()
        await primer.settle()

        // Assert
        XCTAssertEqual(environment.closed.count, 1)
        XCTAssertFalse(primer.isActive)
    }

    func testCancel_LeavesAReservedCaptureToTheSession() async {
        // Arrange
        let environment = PrimerTestEnvironment()
        environment.holdOpens = true
        let primer = makePrimer(environment)
        primer.pressBegan(at: 100)
        await waitUntil { environment.pendingOpens.count == 1 }
        let reservation = primer.reserve()

        // Act
        primer.cancel()
        environment.scheduler.fire(delay: safetyTimeout)
        environment.resumeOpens()
        let reserved = await reservation?.value
        await primer.settle()

        // Assert
        XCTAssertNotNil(reserved)
        XCTAssertTrue(environment.closed.isEmpty)
    }

    func testStaleSafetyTimeout_DoesNotCloseANewerPressesMicrophone() async {
        // Arrange
        let environment = PrimerTestEnvironment()
        let primer = makePrimer(environment)
        primer.pressBegan(at: 100)
        await primer.settle()
        let firstTimeout = environment.scheduler.entries.count - 1
        primer.pressEnded(at: 100.1)
        await primer.settle()
        primer.pressBegan(at: 102)
        await primer.settle()

        // Act: the first press's timer fires late, as if its cancel raced it.
        environment.scheduler.entries[firstTimeout].action()
        await primer.settle()

        // Assert
        XCTAssertEqual(environment.opened.count, 2)
        XCTAssertEqual(environment.closed.count, 1)
        XCTAssertTrue(environment.opened.first?.isClosed == true)
        XCTAssertTrue(primer.isActive)
    }

    func testNewPress_OpensOnlyAfterTheCancelledPressHasClosed() async {
        // Arrange
        let environment = PrimerTestEnvironment()
        environment.holdOpens = true
        let primer = makePrimer(environment)
        primer.pressBegan(at: 100)
        await waitUntil { environment.pendingOpens.count == 1 }
        primer.pressEnded(at: 100.05)

        // Act
        primer.pressBegan(at: 101)
        await Task.yield()
        let opensWhileFirstPending = environment.pendingOpens.count
        environment.resumeOpens()
        await waitUntil { environment.pendingOpens.count == 1 }
        environment.resumeOpens()
        await primer.settle()

        // Assert: the stale open was closed before the newer one started, and
        // the newer press still owns a live capture.
        XCTAssertEqual(opensWhileFirstPending, 1)
        XCTAssertEqual(environment.opened.count, 2)
        XCTAssertEqual(environment.closed.map(\.keyDownUptime), [100])
        XCTAssertTrue(primer.isActive)
        let reserved = await primer.reserve()?.value
        XCTAssertEqual(reserved?.keyDownUptime, 101)
    }

    func testEnqueueClose_ClosesAnUnusedReservedCapture() async {
        // Arrange
        let environment = PrimerTestEnvironment()
        let primer = makePrimer(environment)
        primer.pressBegan(at: 100)
        await primer.settle()
        guard let reserved = await primer.reserve()?.value else {
            return XCTFail("expected a capture")
        }

        // Act
        primer.enqueueClose(reserved)
        await primer.settle()

        // Assert
        XCTAssertTrue(reserved.isClosed)
    }
}
