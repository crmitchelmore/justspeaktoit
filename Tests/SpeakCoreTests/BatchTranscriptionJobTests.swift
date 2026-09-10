import XCTest
@testable import SpeakCore

/// The polling loop and the credential boundary shared by the batch clients.
final class BatchTranscriptionJobTests: XCTestCase {

    // MARK: - Polling deadline

    /// The configured timeout bounds the whole operation *and* each attempt.
    /// Without that, a request that stalls holds the job open for URLSession's
    /// own limits, which are far longer than this operation's deadline.
    func testAStalledAttemptIsAbandonedAtTheOperationDeadline() async {
        let started = Date()
        await assertThrowsAsync(
            try await BatchTranscriptionJob.poll(
                interval: 0,
                timeout: 0.2,
                sleep: { _ in },
                step: { () -> BatchTranscriptionJob.Poll<Int> in
                    // Longer than any test should wait; the deadline must win.
                    try await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                    XCTFail("the stalled attempt should have been abandoned")
                    return .finished(0)
                })
        ) { XCTAssertEqual($0 as? BatchTranscriptionJobError, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testAPendingJobStillTimesOutAcrossAttempts() async {
        let attempts = Counter()
        await assertThrowsAsync(
            try await BatchTranscriptionJob.poll(
                interval: 0,
                timeout: 0.2,
                sleep: { _ in try await Task.sleep(nanoseconds: 20_000_000) },
                step: { () -> BatchTranscriptionJob.Poll<Int> in
                    await attempts.increment()
                    return .pending
                })
        ) { XCTAssertEqual($0 as? BatchTranscriptionJobError, .timedOut) }
        let count = await attempts.value
        XCTAssertGreaterThan(count, 0)
    }

    func testAFinishedAttemptReturnsItsValueWithoutWaiting() async throws {
        let value = try await BatchTranscriptionJob.poll(
            interval: 0,
            timeout: 5,
            sleep: { _ in XCTFail("must not wait after finishing") },
            step: { BatchTranscriptionJob.Poll.finished(42) })
        XCTAssertEqual(value, 42)
    }

    /// `poll` is public, so a caller can hand it a negative or non-finite
    /// interval. Left unchecked, the default sleep clamps a negative interval
    /// to zero and one pending job becomes an unbounded request loop.
    func testInvalidPollingSchedulesAreRejectedBeforeAnyRequest() async {
        let schedules: [(TimeInterval, TimeInterval)] = [
            (-1, 900), (.nan, 900), (.infinity, 900),
            (2, -1), (2, 0), (2, .nan), (2, .infinity)
        ]
        for (interval, timeout) in schedules {
            await assertThrowsAsync(
                try await BatchTranscriptionJob.poll(
                    interval: interval,
                    timeout: timeout,
                    sleep: { _ in },
                    step: { () -> BatchTranscriptionJob.Poll<Int> in
                        XCTFail("must not poll with interval \(interval) and timeout \(timeout)")
                        return .finished(0)
                    })
            ) {
                XCTAssertEqual(
                    $0 as? BatchTranscriptionJobError, .invalidPollingSchedule,
                    "interval \(interval), timeout \(timeout)")
            }
        }
    }

    func testNanosecondConversionSaturatesRatherThanTrapping() {
        XCTAssertEqual(BatchTranscriptionJob.nanoseconds(0), 0)
        XCTAssertEqual(BatchTranscriptionJob.nanoseconds(-5), 0)
        XCTAssertEqual(BatchTranscriptionJob.nanoseconds(1.5), 1_500_000_000)
        XCTAssertEqual(BatchTranscriptionJob.nanoseconds(.infinity), .max)
        XCTAssertEqual(BatchTranscriptionJob.nanoseconds(1e30), .max)
    }

    // MARK: - Credential boundary

    /// Batch clients attach a reusable account key to every request, so this
    /// predicate decides whether a URL taken from a provider response may be
    /// requested with that key.
    func testSameOriginComparesSchemeHostAndEffectivePort() {
        let origin = URL(string: "https://api.gladia.io")!
        for onOrigin in [
            "https://api.gladia.io/v2/pre-recorded/abc",
            "https://API.Gladia.IO/v2/pre-recorded/abc",
            "https://api.gladia.io:443/v2/pre-recorded/abc"
        ] {
            XCTAssertTrue(
                BatchTranscriptionJob.isSameOrigin(URL(string: onOrigin)!, as: origin), onOrigin)
        }
        for offOrigin in [
            "http://api.gladia.io/v2/pre-recorded/abc",
            "https://api.gladia.io.evil.example/v2",
            "https://evil.example/v2",
            "https://api.gladia.io:8443/v2",
            "file:///etc/passwd",
            "/v2/pre-recorded/abc"
        ] {
            XCTAssertFalse(
                BatchTranscriptionJob.isSameOrigin(URL(string: offOrigin)!, as: origin), offOrigin)
        }
    }

    func testAbandonmentCoversBothCancellationSpellingsAndTheLocalDeadline() {
        XCTAssertTrue(BatchTranscriptionJob.abandonsAcceptedJob(CancellationError()))
        XCTAssertTrue(BatchTranscriptionJob.abandonsAcceptedJob(URLError(.cancelled)))
        XCTAssertTrue(BatchTranscriptionJob.abandonsAcceptedJob(BatchTranscriptionJobError.timedOut))
        XCTAssertFalse(BatchTranscriptionJob.abandonsAcceptedJob(URLError(.timedOut)))
        XCTAssertFalse(
            BatchTranscriptionJob.abandonsAcceptedJob(TranscriptionProviderError.httpError(500, "")))
        XCTAssertFalse(
            BatchTranscriptionJob.abandonsAcceptedJob(BatchTranscriptionJobError.jobFailed("X", "")))
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { self.value += 1 }
}
