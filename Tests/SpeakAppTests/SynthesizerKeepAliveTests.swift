import XCTest
@testable import SpeakApp

/// The system voice's writer must outlive every synthesizer callback: freeing
/// it while one is queued crashed Alpha 3.2.0 in `swift_unknownObjectWeakInit`.
final class SynthesizerKeepAliveTests: XCTestCase {
    private final class Owner {}

    private final class Harness: @unchecked Sendable {
        var scheduled: [(TimeInterval, @Sendable () -> Void)] = []
        var dropped: [Owner] = []

        func make(grace: TimeInterval = 10) -> SynthesizerKeepAlive<Owner> {
            SynthesizerKeepAlive(
                grace: grace,
                schedule: { delay, work in self.scheduled.append((delay, work)) },
                drop: { self.dropped.append($0) }
            )
        }
    }

    func testLongSynthesis_IsNeverReleasedBeforeTheOutcomeSettles() {
        let harness = Harness()
        let keepAlive = harness.make()
        weak var weakOwner: Owner?
        do {
            let owner = Owner()
            weakOwner = owner
            keepAlive.retain(owner)
        }

        XCTAssertTrue(harness.scheduled.isEmpty, "No time bound may start while synthesis runs")
        XCTAssertNotNil(weakOwner)
        XCTAssertTrue(keepAlive.isRetaining)
    }

    func testSynthesizerStopped_ReleasesOnceThroughDrop() {
        let harness = Harness()
        let keepAlive = harness.make()
        keepAlive.retain(Owner())
        keepAlive.outcomeSettled()

        keepAlive.synthesizerStopped()
        keepAlive.synthesizerStopped()

        XCTAssertEqual(harness.dropped.count, 1)
        XCTAssertFalse(keepAlive.isRetaining)
    }

    func testSettledOutcome_FallsBackAfterTheGraceWhenTheSynthesizerNeverStops() {
        let harness = Harness()
        let keepAlive = harness.make(grace: 7)
        keepAlive.retain(Owner())

        keepAlive.outcomeSettled()
        keepAlive.outcomeSettled()

        XCTAssertEqual(harness.scheduled.count, 1)
        XCTAssertEqual(harness.scheduled.first?.0, 7)
        XCTAssertTrue(keepAlive.isRetaining)
        harness.scheduled.first?.1()
        XCTAssertEqual(harness.dropped.count, 1)
        XCTAssertFalse(keepAlive.isRetaining)
    }

    func testFallbackAfterStop_DoesNotReleaseAgain() {
        let harness = Harness()
        let keepAlive = harness.make()
        keepAlive.retain(Owner())
        keepAlive.outcomeSettled()
        keepAlive.synthesizerStopped()

        harness.scheduled.first?.1()

        XCTAssertEqual(harness.dropped.count, 1)
    }

    func testDefaultDrop_FreesTheOwnerOnTheMainQueue() {
        let keepAlive = SynthesizerKeepAlive<Owner>(grace: 10)
        weak var weakOwner: Owner?
        do {
            let owner = Owner()
            weakOwner = owner
            keepAlive.retain(owner)
        }
        keepAlive.synthesizerStopped()
        XCTAssertNotNil(weakOwner, "The last release is deferred to the main queue")

        let freed = expectation(description: "owner freed")
        DispatchQueue.main.async {
            if weakOwner == nil { freed.fulfill() }
        }
        wait(for: [freed], timeout: 2)
    }
}
