import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopCorrectionObservationTests: XCTestCase {
    func testOwnedReadback_UsesCanonicalDelayAndReturnsOnlyTheLeaseText() async throws {
        let native = ObservationFixture()
        let observation = DesktopCorrectionObservation(native: native)
        let text = try await observation.sample(original: "Susie") { seconds in
            XCTAssertEqual(seconds, 10)
        }
        XCTAssertEqual(text, "Susy")
        XCTAssertEqual(native.begins, 1)
        XCTAssertEqual(native.reads, 1)
        XCTAssertEqual(observation.application, "Synthetic")
        observation.cancel()
        XCTAssertFalse(observation.isCurrent)
    }

    func testCancelledWait_NeverReadsTheNativeField() async throws {
        let native = ObservationFixture()
        let observation = DesktopCorrectionObservation(native: native)
        do {
            _ = try await observation.sample(original: "Susie") { _ in observation.cancel() }
            XCTFail("A cancelled lease returned text")
        } catch is CancellationError {
            XCTAssertEqual(native.reads, 0)
        }
    }

    func testLateBlockedNativeRead_IsFencedAfterCancellation() async throws {
        let entered = expectation(description: "read entered")
        let native = ObservationFixture(entered: entered)
        let observation = DesktopCorrectionObservation(native: native)
        let task = Task { try await observation.sample(original: "Susie", wait: { _ in }) }
        await fulfillment(of: [entered], timeout: 3)
        observation.cancel()
        native.release()
        do { _ = try await task.value; XCTFail("Late native text escaped cancellation") } catch is CancellationError {}
    }

    func testCancelledDuringNativeBegin_FencesItsLateCompletion() async throws {
        let entered = expectation(description: "begin entered")
        let native = ObservationFixture(beginEntered: entered)
        let observation = DesktopCorrectionObservation(native: native)
        let task = Task { try await observation.sample(original: "Susie", wait: { _ in }) }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel()
        native.release()
        do {
            _ = try await task.value
            XCTFail("Late range capture escaped cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(native.reads, 0)
    }

    func testEmptyOversizedAndUnsupportedRanges_AreRejected() async throws {
        let native = ObservationFixture()
        for original in ["", String(repeating: "x", count: AutoCorrectionLearningPolicy.maximumUTF16Units + 1)] {
            let observation = DesktopCorrectionObservation(native: native)
            do {
                _ = try await observation.sample(original: original, wait: { _ in })
                XCTFail("An unbounded or empty insertion was observed")
            } catch DesktopCorrectionObservationError.unsupported {}
        }
        XCTAssertEqual(native.begins, 0)
        let unavailable = DesktopCorrectionObservation(native: ObservationFixture(unsupported: true))
        do {
            _ = try await unavailable.sample(original: "Susie", wait: { _ in })
            XCTFail("An unsupported field was read")
        } catch DesktopCorrectionObservationError.unsupported {}
    }
}

private final class ObservationFixture: DesktopCorrectionReadback, @unchecked Sendable {
    let application: String? = "Synthetic"
    private let condition = NSCondition()
    private var beginCount = 0
    private var readCount = 0
    private var released = false
    private let entered: XCTestExpectation?
    private let beginEntered: XCTestExpectation?
    private let unsupported: Bool
    var begins: Int { condition.withLock { beginCount } }
    var reads: Int { condition.withLock { readCount } }

    init(entered: XCTestExpectation? = nil, unsupported: Bool = false, beginEntered: XCTestExpectation? = nil) {
        self.entered = entered
        self.unsupported = unsupported
        self.beginEntered = beginEntered
    }

    func begin(original: String) throws {
        condition.lock()
        defer { condition.unlock() }
        beginCount += 1
        beginEntered?.fulfill()
        while beginEntered != nil && !released { condition.wait() }
        if unsupported { throw DesktopCorrectionObservationError.unsupported }
    }

    func read() throws -> String {
        condition.lock()
        defer { condition.unlock() }
        readCount += 1
        entered?.fulfill()
        while entered != nil && !released { condition.wait() }
        return "Susy"
    }

    func release() {
        condition.withLock { released = true; condition.broadcast() }
    }

    func cancel() {}
}
