import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopRecordingFeedbackTests: XCTestCase {
    func testPendingPreview_DoesNotReplayAfterAnInterveningRecordingEnds() async throws {
        let fixture = FeedbackFixture()
        try await fixture.feedback.configure(DesktopRecordingFeedbackPreferences(enabled: false))
        let preview = Task { await fixture.feedback.preview(.start) }
        try await eventually { await fixture.loader.count == 1 }
        let id = UUID()
        await fixture.feedback.recordingRequested(id)
        await fixture.feedback.captureReady(id)
        await fixture.feedback.recordingFinished(id)
        let output = await fixture.loader.release(0)
        await preview.value
        XCTAssertTrue(output.events.isEmpty)
        await fixture.feedback.close()
        XCTAssertEqual(output.closes, 1)
    }
    func testAsynchronousDeviceFailure_IsReportedAndRetiresItsChannel() async throws {
        let fixture = FeedbackFixture()
        let output = try await fixture.warm()
        output.failOutput("Synthetic device disconnected.")
        try await eventually { output.closes == 1 }
        XCTAssertTrue(fixture.messages.values.contains { $0.contains("Synthetic device disconnected.") })
        await fixture.feedback.close()
        XCTAssertEqual(output.closes, 1)
    }

    func testLateFailureFromRetiredOutput_CannotRetireReplacement() async throws {
        let fixture = FeedbackFixture()
        let previous = try await fixture.warm()
        try await fixture.feedback.configure(DesktopRecordingFeedbackPreferences(profile: .soft))
        try await eventually { await fixture.loader.count == 2 }
        let replacement = await fixture.loader.release(1)
        await fixture.feedback.preview(.stop)
        previous.failOutput("Stale failure.")
        await fixture.feedback.recordingRequested(UUID())
        XCTAssertFalse(fixture.messages.values.contains { $0.contains("Stale failure.") })
        XCTAssertEqual(replacement.closes, 0)
        await fixture.feedback.close()
        XCTAssertEqual(replacement.closes, 1)
    }
    func testPreferences_RejectNonfiniteAndOutOfRangeVolume() throws {
        for volume: Float in [.nan, .infinity, -.infinity, -0.01, 1.01] {
            XCTAssertThrowsError(try DesktopRecordingFeedbackPreferences(volume: volume))
        }
        XCTAssertEqual(try DesktopRecordingFeedbackPreferences().volume, Float(RecordingFeedbackDefaults.volume))
    }

    func testDisabled_DoesNotPrepareOrPlayButExplicitPreviewWorks() async throws {
        let fixture = FeedbackFixture()
        try await fixture.feedback.configure(DesktopRecordingFeedbackPreferences(enabled: false))
        let id = UUID()
        await fixture.feedback.recordingRequested(id)
        await fixture.feedback.captureReady(id)
        await fixture.feedback.recordingFinished(id)
        let initialRequests = await fixture.loader.count
        XCTAssertEqual(initialRequests, 0)
        let preview = Task { await fixture.feedback.preview(.start) }
        try await eventually { await fixture.loader.count == 1 }
        let output = await fixture.loader.release(0)
        await preview.value
        XCTAssertEqual(output.events.map(\.sound), [.start])
        XCTAssertEqual(output.events[0].gain, 0.49, accuracy: 0.000_001)
        await fixture.feedback.close()
        XCTAssertEqual(output.closes, 1)
    }

    func testReadyStartAndOwnedStop_PlayOnceAndUseSquaredGain() async throws {
        let fixture = FeedbackFixture()
        let output = try await fixture.warm()
        let id = UUID()
        await fixture.feedback.recordingRequested(id)
        XCTAssertEqual(output.events.count, 1)
        await fixture.feedback.captureReady(UUID())
        XCTAssertEqual(output.events.count, 1)
        await fixture.feedback.captureReady(id)
        await fixture.feedback.captureReady(id)
        await fixture.feedback.recordingFinished(UUID())
        await fixture.feedback.recordingFinished(id)
        await fixture.feedback.recordingFinished(id)
        XCTAssertEqual(output.events.map(\.sound), [.stop, .start, .stop])
        XCTAssertTrue(output.events.allSatisfy { abs($0.gain - 0.49) < 0.000_001 })
        await fixture.feedback.close()
    }

    func testCancelledStartup_RejectsLateReadyAndStop() async throws {
        let fixture = FeedbackFixture()
        let output = try await fixture.warm()
        let id = UUID()
        await fixture.feedback.recordingRequested(id)
        await fixture.feedback.cancelRecording(id)
        await fixture.feedback.captureReady(id)
        await fixture.feedback.recordingFinished(id)
        XCTAssertEqual(output.events.map(\.sound), [.stop])
        XCTAssertGreaterThanOrEqual(output.stops, 2)
        await fixture.feedback.close()
    }

    func testLatePreparation_DoesNotReplaySkippedCue() async throws {
        let fixture = FeedbackFixture()
        try await fixture.feedback.configure(DesktopRecordingFeedbackPreferences())
        try await eventually { await fixture.loader.count == 1 }
        let id = UUID()
        await fixture.feedback.recordingRequested(id)
        await fixture.feedback.captureReady(id)
        XCTAssertTrue(fixture.messages.values.contains { $0.contains("skipped rather than delayed") })
        let output = await fixture.loader.release(0)
        await fixture.feedback.cancelRecording(id)
        await fixture.feedback.preview(.stop)
        XCTAssertEqual(output.events.map(\.sound), [.stop])
        await fixture.feedback.close()
    }

    func testProfileReplacement_ClosesStaleLoadWithoutPlayingIt() async throws {
        let fixture = FeedbackFixture()
        try await fixture.feedback.configure(DesktopRecordingFeedbackPreferences())
        try await eventually { await fixture.loader.count == 1 }
        try await fixture.feedback.configure(DesktopRecordingFeedbackPreferences(profile: .soft))
        try await eventually { await fixture.loader.count == 2 }
        let current = await fixture.loader.release(1)
        await fixture.feedback.preview(.stop)
        let stale = await fixture.loader.release(0)
        await fixture.feedback.close()
        let profiles = await fixture.loader.profiles
        XCTAssertEqual(profiles, [.classic, .soft])
        XCTAssertTrue(stale.events.isEmpty)
        XCTAssertEqual(stale.closes, 1)
        XCTAssertEqual(current.events.map(\.sound), [.stop])
        XCTAssertEqual(current.closes, 1)
    }

    func testVolumeChange_ReusesPreparedChannelAndDisableClosesOnlyIt() async throws {
        let fixture = FeedbackFixture()
        let output = try await fixture.warm()
        try await fixture.feedback.configure(DesktopRecordingFeedbackPreferences(volume: 0.2))
        let id = UUID()
        await fixture.feedback.recordingRequested(id)
        await fixture.feedback.captureReady(id)
        XCTAssertEqual(try XCTUnwrap(output.events.last).gain, 0.04, accuracy: 0.000_001)
        let count = await fixture.loader.count
        XCTAssertEqual(count, 1)
        try await fixture.feedback.configure(DesktopRecordingFeedbackPreferences(enabled: false))
        await fixture.feedback.recordingFinished(id)
        await fixture.feedback.close()
        XCTAssertEqual(output.events.map(\.sound), [.stop, .start])
        XCTAssertEqual(output.closes, 1)
    }

    func testClose_WaitsForCancelledLoadAndRejectsAllLaterCues() async throws {
        let fixture = FeedbackFixture()
        try await fixture.feedback.configure(DesktopRecordingFeedbackPreferences())
        try await eventually { await fixture.loader.count == 1 }
        let closed = FeedbackMessages()
        let close = Task {
            await fixture.feedback.close()
            closed.append("ended")
        }
        try await eventually { await fixture.loader.cancelled(0) }
        XCTAssertTrue(closed.values.isEmpty)
        let output = await fixture.loader.release(0)
        await close.value
        await fixture.feedback.close()
        try await fixture.feedback.configure(DesktopRecordingFeedbackPreferences())
        let id = UUID()
        await fixture.feedback.recordingRequested(id)
        await fixture.feedback.captureReady(id)
        await fixture.feedback.recordingFinished(id)
        await fixture.feedback.preview(.start)
        XCTAssertTrue(output.events.isEmpty)
        XCTAssertEqual(output.closes, 1)
        XCTAssertEqual(closed.values, ["ended"])
    }

    func testFailures_AreReportedRatherThanConvertedToSilentSuccess() async throws {
        let fixture = FeedbackFixture()
        try await fixture.feedback.configure(DesktopRecordingFeedbackPreferences())
        try await eventually { await fixture.loader.count == 1 }
        await fixture.loader.fail(0)
        try await eventually { fixture.messages.values.contains { $0.contains("preparation failed") } }
        let preview = Task { await fixture.feedback.preview(.start) }
        try await eventually { await fixture.loader.count == 2 }
        let output = await fixture.loader.release(1, failing: true)
        await preview.value
        XCTAssertTrue(fixture.messages.values.contains { $0.contains("Recording sound failed") })
        await fixture.feedback.close()
        XCTAssertTrue(fixture.messages.values.contains { $0.contains("cleanup failed") })
        XCTAssertEqual(output.closes, 1)
    }

    private func eventually(
        _ condition: @escaping @Sendable () async -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Feedback operation did not reach its expected state.", file: file, line: line)
                throw FeedbackTestError.failed
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private struct FeedbackFixture: Sendable {
    let loader = FeedbackTestLoader()
    let messages = FeedbackMessages()
    let feedback: DesktopRecordingFeedback

    init() {
        let messages = self.messages
        feedback = DesktopRecordingFeedback(loader: loader, report: { messages.append($0) })
    }

    func warm() async throws -> FeedbackTestOutput {
        try await feedback.configure(DesktopRecordingFeedbackPreferences())
        let preview = Task { await feedback.preview(.stop) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await loader.isEmpty {
            guard ContinuousClock.now < deadline else { throw FeedbackTestError.failed }
            try await Task.sleep(for: .milliseconds(2))
        }
        let output = await loader.release(0)
        await preview.value
        return output
    }
}

private actor FeedbackTestLoader: DesktopRecordingFeedbackLoader {
    private struct Request {
        let profile: RecordingFeedbackProfile
        let continuation: CheckedContinuation<any DesktopRecordingFeedbackOutput, Error>
        let cancellation: FeedbackMessages
    }
    private var requests: [Request] = []

    var count: Int { requests.count }
    var isEmpty: Bool { requests.isEmpty }
    var profiles: [RecordingFeedbackProfile] { requests.map(\.profile) }

    func prepare(profile: RecordingFeedbackProfile) async throws -> any DesktopRecordingFeedbackOutput {
        let cancellation = FeedbackMessages()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                requests.append(Request(profile: profile, continuation: continuation, cancellation: cancellation))
            }
        } onCancel: {
            cancellation.append("cancelled")
        }
    }

    func release(_ index: Int, failing: Bool = false) -> FeedbackTestOutput {
        let output = FeedbackTestOutput(failing: failing)
        requests[index].continuation.resume(returning: output)
        return output
    }

    func fail(_ index: Int) { requests[index].continuation.resume(throwing: FeedbackTestError.failed) }
    func cancelled(_ index: Int) -> Bool { !requests[index].cancellation.values.isEmpty }
}

private final class FeedbackTestOutput: DesktopRecordingFeedbackOutput, @unchecked Sendable {
    struct Event: Sendable {
        let sound: RecordingFeedbackSound
        let gain: Float
    }
    private let lock = NSLock()
    private let failing: Bool
    private var played: [Event] = []
    private var stopCount = 0
    private var closeCount = 0
    private var failureHandler: (@Sendable (String) -> Void)?
    init(failing: Bool) { self.failing = failing }
    var events: [Event] { lock.withLock { played } }
    var stops: Int { lock.withLock { stopCount } }
    var closes: Int { lock.withLock { closeCount } }
    func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.withLock { failureHandler = handler }
    }
    func failOutput(_ message: String) { lock.withLock { failureHandler }?(message) }
    func play(_ sound: RecordingFeedbackSound, gain: Float) throws {
        if failing { throw FeedbackTestError.failed }
        lock.withLock { played.append(Event(sound: sound, gain: gain)) }
    }
    func stop() { lock.withLock { stopCount += 1 } }
    func close() async throws {
        lock.withLock { closeCount += 1 }
        if failing { throw FeedbackTestError.failed }
    }
}

private final class FeedbackMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    var values: [String] { lock.withLock { messages } }
    func append(_ message: String) { lock.withLock { messages.append(message) } }
}

private enum FeedbackTestError: Error { case failed }
