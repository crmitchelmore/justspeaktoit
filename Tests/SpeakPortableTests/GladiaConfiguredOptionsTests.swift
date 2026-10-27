import Foundation
import XCTest
@testable import SpeakCore

final class GladiaConfiguredOptionsTests: XCTestCase {
    func testRequiredOptionsDeclareActualStageSumAndCapturedValues() {
        let normal = GladiaConfiguredFixture()
        let custom = GladiaConfiguredFixture(grace: 2, window: 4)
        XCTAssertEqual(normal.client.finalisationBudget, 4.5)
        XCTAssertEqual(custom.client.finalisationBudget, 9)
        XCTAssertEqual(GladiaHarness().client.finalisationBudget, GladiaLive.finishBudget)
    }

    func testExistingSanitationKeepsNegativeAndNonfiniteOptionsBounded() {
        for value in [-1.0, .infinity, -.infinity, .nan] {
            let fixture = GladiaConfiguredFixture(grace: value, window: value)
            XCTAssertEqual(fixture.client.finalisationBudget, value == -1 ? 3 : 4.5)
        }
    }

    func testNumericallyRepresentableDelaysWithUnrepresentableFiniteTotalRefuseBeforeHTTP() async {
        let delay: TimeInterval = 5_000_000_000
        let nanoseconds = (delay * 1_000_000_000).rounded(.up)
        XCTAssertNotNil(Int64(exactly: nanoseconds))
        XCTAssertNotNil(Int(exactly: nanoseconds))
        let total = GladiaConfiguredTiming.drain + delay + GladiaConfiguredTiming.control + delay
        XCTAssertTrue(total.isFinite)
        XCTAssertNil(Int64(exactly: (total * 1_000_000_000).rounded(.up)))
        // Numeric conversion and the clock's absolute headroom are distinct:
        // Linux Dispatch can reject even an individual delay this large.
        await assertRefused(grace: delay, window: delay)

        // Exercise the combined guard even when the absolute clock refuses
        // the first numeric fixture. Both phases must be schedulable alone.
        guard let individual = [delay, 3_000_000_000].first(where: {
            GladiaConfiguredTiming.deadline(after: $0) != nil
        }) else {
            XCTFail("No large individually schedulable delay for the combined-deadline fixture")
            return
        }
        let combined = GladiaConfiguredTiming.drain + individual + GladiaConfiguredTiming.control + individual
        XCTAssertNotNil(GladiaConfiguredTiming.deadline(after: individual))
        XCTAssertNil(GladiaConfiguredTiming.deadline(after: combined))
        await assertRefused(grace: individual, window: individual)
    }

    func testNanosecondsProductAndNonfiniteSumCannotScheduleOrInitiate() async {
        await assertRefused(grace: 10_000_000_000, window: 1.5)
        await assertRefused(grace: .greatestFiniteMagnitude, window: 1.5)
        await assertRefused(grace: .greatestFiniteMagnitude, window: .greatestFiniteMagnitude)
    }

    func testCheckedConversionBoundaryAndDistantFutureRefuseWithoutIntegerTrap() {
        let boundary = Double(Int64.max) / 1_000_000_000
        XCTAssertNil(GladiaConfiguredTiming.deadline(after: boundary.nextUp))
        XCTAssertNil(GladiaConfiguredTiming.deadline(after: boundary))
        let below = boundary.nextDown
        // The integer conversion itself is representable; the actual clock's
        // remaining range can still reject the resulting absolute deadline.
        XCTAssertNotNil(Int64(exactly: (below * 1_000_000_000).rounded(.up)))
        XCTAssertNil(GladiaConfiguredTiming.deadline(after: 1, now: .distantFuture))
        XCTAssertNil(GladiaConfiguredTiming.deadline(after: -1))
        XCTAssertNil(GladiaConfiguredTiming.deadline(after: .nan))
        let timing = GladiaConfiguredTiming(options: GladiaConfiguredFixture.options(grace: 0, window: nil))
        XCTAssertTrue(timing?.isSchedulable() == true)
        XCTAssertFalse(timing?.isSchedulable(now: .distantFuture) == true)
    }

    func testLargeRepresentableOptionsUseInjectedSchedulerWithoutInstallingLongRealTimers() async throws {
        let fixture = GladiaConfiguredFixture(grace: 1_000_000, window: 1_000_000)
        defer { fixture.client.cancel() }
        XCTAssertEqual(fixture.client.finalisationBudget, 2_000_003)
        fixture.start()
        let socket = try XCTUnwrap(fixture.sockets.sockets.last)
        fixture.client.sendAudio(GladiaHarness.pcm(0)); socket.completeSend()
        let finish = try await fixture.beginFinish(in: self)
        XCTAssertTrue(fixture.clock.scheduledDelays.contains(1_000_000))
        finish.task.cancel()
        let result = try await fixture.result(finish)
        XCTAssertNil(result)
    }

    func testUnsupportedExtremeSampleRatesFailBeforeFramerOrTransportMath() async {
        for rate in [Int.min, -1, 0, Int.max] {
            let fixture = GladiaConfiguredFixture(sampleRate: rate)
            fixture.start(open: false)
            XCTAssertEqual(fixture.log.errors.first as? GladiaStreamingError, .invalidSampleRate(rate))
            XCTAssertTrue(fixture.sessions.requests.isEmpty)
            XCTAssertTrue(fixture.clock.scheduledDelays.isEmpty)
            let result = await fixture.client.finishAndWait()
            XCTAssertNil(result)
            let legacy = GladiaHarness(sampleRate: rate)
            legacy.start()
            XCTAssertEqual(legacy.log.errors.first as? GladiaStreamingError, .invalidSampleRate(rate))
            XCTAssertTrue(legacy.sessions.requests.isEmpty)
        }
    }

    private func assertRefused(grace: TimeInterval, window: TimeInterval) async {
        let fixture = GladiaConfiguredFixture(grace: grace, window: window)
        XCTAssertNil(fixture.client.finalisationBudget)
        fixture.start(open: false)
        XCTAssertEqual(fixture.log.errors.count, 1)
        XCTAssertTrue(fixture.log.errors.first is GladiaTimingConfigurationError)
        XCTAssertTrue(fixture.sessions.requests.isEmpty)
        XCTAssertTrue(fixture.sockets.sockets.isEmpty)
        XCTAssertTrue(fixture.clock.scheduledDelays.isEmpty)
        let result = await fixture.client.finishAndWait()
        XCTAssertNil(result)
    }
}
