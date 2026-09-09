#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

@MainActor
final class LegacyAppleFinalisationTests: XCTestCase {
    func testPartialThenDelayedFinal_waitsAndReturnsFinalExactlyOnce() async throws {
        let fixture = Fixture()
        try await fixture.transcriber.start()
        fixture.send("the last", final: false)
        let stopping = Task { await fixture.transcriber.stop() }
        await fulfillment(of: [fixture.finishing], timeout: 2)
        XCTAssertEqual(fixture.operations, ["end", "finish"])
        fixture.send("the last word", final: false)
        await Task.yield()
        XCTAssertTrue(fixture.outputs.isEmpty, "A partial is not task completion")
        XCTAssertEqual(fixture.starts, 1)
        fixture.send("The last word.", final: true, confidence: 0.9)
        let result = await stopping.value
        XCTAssertEqual(result.text, "The last word.")
        XCTAssertEqual(result.segments.map(\.text), ["The last word."])
        XCTAssertEqual(result.confidence, 0.9)
        XCTAssertEqual(fixture.outputs.count, 1)
        XCTAssertEqual(fixture.starts, 1, "Finalisation must not restart recognition or reinstall the tap")
        XCTAssertEqual(fixture.operations, ["end", "finish", "cancel"])
        XCTAssertEqual(fixture.deadlineCancellations, 1)
        XCTAssertEqual(fixture.releases, 1)
        fixture.send("late duplicate", final: true)
        XCTAssertEqual(fixture.outputs.count, 1)
        XCTAssertEqual(fixture.transcriber.partialText, "The last word.")
    }

    func testTimeout_preservesLatestPartialAndSegments() async throws {
        let fixture = Fixture()
        try await fixture.transcriber.start()
        fixture.send("early", final: false)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let recordingURL = try fixture.transcriber.audioRecorder.startRecording(format: format)
        defer { try? FileManager.default.removeItem(at: recordingURL) }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<4800 { samples[index] = 0.1 }
        fixture.transcriber.audioRecorder.writeBuffer(buffer)
        let stopping = Task { await fixture.transcriber.stop() }
        await fulfillment(of: [fixture.finishing], timeout: 2)
        fixture.send("latest usable", final: false, confidence: 0.7)
        fixture.deadlines[0]()
        let result = await stopping.value
        XCTAssertFalse(fixture.transcriber.audioRecorder.isRecording)
        XCTAssertNil(fixture.transcriber.audioRecorder.currentFileURL)
        XCTAssertGreaterThan(try AVAudioFile(forReading: recordingURL).length, 0)
        XCTAssertEqual(result.text, "latest usable")
        XCTAssertEqual(result.segments.map(\.text), ["latest usable"])
        XCTAssertEqual(result.confidence, 0.7)
        XCTAssertEqual(fixture.outputs.count, 1)
        XCTAssertFalse(fixture.transcriber.isRunning)
        XCTAssertEqual(fixture.releases, 1)
    }

    func testNoCallback_deadlineReturnsEmptyInputWithoutInventingText() async throws {
        let fixture = Fixture()
        try await fixture.transcriber.start()
        let stopping = Task { await fixture.transcriber.stop() }
        await fulfillment(of: [fixture.finishing], timeout: 2)
        fixture.deadlines[0]()
        let result = await stopping.value
        XCTAssertEqual(result.text, "")
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertNil(result.confidence)
        XCTAssertEqual(fixture.outputs.count, 1)
    }

    func testProductionDeadline_boundsUnresponsiveStop() async throws {
        let fixture = Fixture(useRealDeadline: true)
        try await fixture.transcriber.start()
        let completed = expectation(description: "production deadline completed Stop")
        let start = ContinuousClock.now
        let stopping = Task {
            let result = await fixture.transcriber.stop()
            completed.fulfill()
            return result
        }
        await fulfillment(of: [fixture.finishing], timeout: 1)
        XCTAssertTrue(fixture.outputs.isEmpty)
        await fulfillment(of: [completed], timeout: 4)
        // Also release the continuation if this assertion fails, so a regression
        // reports a failure instead of hanging the remainder of the test suite.
        fixture.transcriber.cancel()
        let result = await stopping.value
        XCTAssertTrue(result.text.isEmpty)
        XCTAssertGreaterThanOrEqual(start.duration(to: .now), .seconds(2))
        XCTAssertEqual(fixture.outputs.count, 1)
    }

    func testTerminalError_preservesUsableResultAndReportsErrorWithoutWaitingForDeadline() async throws {
        let fixture = Fixture()
        try await fixture.transcriber.start()
        fixture.send("retained", final: false)
        let stopping = Task { await fixture.transcriber.stop() }
        await fulfillment(of: [fixture.finishing], timeout: 2)
        fixture.callbacks[0](nil, NSError(domain: "test.recognition", code: 1))
        let result = await stopping.value
        XCTAssertEqual(result.text, "retained")
        XCTAssertEqual(result.segments.map(\.text), ["retained"])
        XCTAssertEqual(fixture.errors.count, 1)
        XCTAssertNotNil(fixture.transcriber.error)
        XCTAssertEqual(fixture.deadlineCancellations, 1)
        XCTAssertEqual(fixture.starts, 1)
        XCTAssertEqual(fixture.outputs.count, 1)
    }

    func testResultAndErrorTogether_retainsThatResultAndExposesError() async throws {
        let fixture = Fixture()
        try await fixture.transcriber.start()
        let stopping = Task { await fixture.transcriber.stop() }
        await fulfillment(of: [fixture.finishing], timeout: 2)
        fixture.callbacks[0](Fixture.update("accepted tail", final: true),
                             NSError(domain: "test.recognition", code: 2))
        let result = await stopping.value
        XCTAssertEqual(result.text, "accepted tail")
        XCTAssertEqual(fixture.errors.count, 1)
        XCTAssertEqual(fixture.starts, 1)
    }

    func testEmptyTerminalResult_retainsLastUsableTextAndSegments() async throws {
        let fixture = Fixture()
        try await fixture.transcriber.start()
        fixture.send("usable words", final: false)
        let stopping = Task { await fixture.transcriber.stop() }
        await fulfillment(of: [fixture.finishing], timeout: 2)
        fixture.send("", final: true)
        let result = await stopping.value
        XCTAssertEqual(result.text, "usable words")
        XCTAssertEqual(result.segments.map(\.text), ["usable words"])
        XCTAssertEqual(result.confidence, 0.8)
    }

    func testFinalDuringEndAudio_doesNotWaitForAnotherCallback() async throws {
        let fixture = Fixture()
        try await fixture.transcriber.start()
        fixture.onEndAudio = { fixture.send("already final", final: true) }
        let result = await fixture.transcriber.stop()
        XCTAssertEqual(result.text, "already final")
        XCTAssertEqual(result.segments.map(\.text), ["already final"])
        XCTAssertEqual(fixture.operations, ["end", "cancel"])
        XCTAssertTrue(fixture.deadlines.isEmpty)
        XCTAssertEqual(fixture.starts, 1)
    }

    func testMultipleUtterances_preservesCommittedTextAndRejectsOldTaskCallbacks() async throws {
        let fixture = Fixture()
        try await fixture.transcriber.start()
        fixture.send("First sentence.", final: true)
        XCTAssertEqual(fixture.starts, 2)
        fixture.callbacks[0](Fixture.update("stale old utterance", final: true), nil)
        fixture.callbacks[0](nil, NSError(domain: "old.task", code: 1))
        XCTAssertTrue(fixture.errors.isEmpty)
        fixture.send("Second", final: false)
        let stopping = Task { await fixture.transcriber.stop() }
        await fulfillment(of: [fixture.finishing], timeout: 2)
        fixture.send("Second sentence.", final: true)
        let result = await stopping.value
        XCTAssertEqual(result.text, "First sentence. Second sentence.")
        XCTAssertEqual(result.segments.map(\.text), ["First sentence.", "Second sentence."])
        XCTAssertEqual(fixture.starts, 2)
        XCTAssertEqual(fixture.outputs.count, 1)
    }

    func testAlreadyCommittedUtterance_emptyNewTaskKeepsMatchingSegmentsOnTimeout() async throws {
        let fixture = Fixture()
        try await fixture.transcriber.start()
        fixture.send("Finished utterance.", final: true)
        let stopping = Task { await fixture.transcriber.stop() }
        await fulfillment(of: [fixture.finishing], timeout: 2)
        fixture.deadlines[0]()
        let result = await stopping.value
        XCTAssertEqual(result.text, "Finished utterance.")
        XCTAssertEqual(result.segments.map(\.text), ["Finished utterance."])
    }

    func testRepeatedStop_joinsSameFinalResultAndPublishesOnlyOnce() async throws {
        let fixture = Fixture()
        try await fixture.transcriber.start()
        let first = Task { await fixture.transcriber.stop() }
        await fulfillment(of: [fixture.finishing], timeout: 2)
        let second = Task { await fixture.transcriber.stop() }
        await Task.yield()
        fixture.send("one result", final: true)
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult.text, "one result")
        XCTAssertEqual(secondResult.text, "one result")
        XCTAssertEqual(secondResult.segments.map(\.text), firstResult.segments.map(\.text))
        XCTAssertEqual(fixture.outputs.count, 1)
        XCTAssertEqual(fixture.releases, 1)
    }

    func testCancelInterruptsWait_andStaleCallbackOrDeadlineCannotAffectNextCapture() async throws {
        let fixture = Fixture()
        try await fixture.transcriber.start()
        fixture.send("discard", final: false)
        let stopping = Task { await fixture.transcriber.stop() }
        await fulfillment(of: [fixture.finishing], timeout: 2)
        let oldReply = fixture.callbacks[0]
        let oldDeadline = fixture.deadlines[0]
        fixture.transcriber.cancel()
        fixture.transcriber.cancel()
        let cancelled = await stopping.value
        XCTAssertTrue(cancelled.text.isEmpty)
        XCTAssertTrue(fixture.outputs.isEmpty)
        XCTAssertEqual(fixture.releases, 1)
        fixture.finishing = expectation(description: "new capture finishing")
        try await fixture.transcriber.start()
        fixture.send("new capture", final: false)
        let newStop = Task { await fixture.transcriber.stop() }
        await fulfillment(of: [fixture.finishing], timeout: 2)
        oldReply(Fixture.update("stale final", final: true), nil)
        oldReply(nil, NSError(domain: "stale.error", code: 1))
        oldDeadline()
        await Task.yield()
        XCTAssertEqual(fixture.transcriber.partialText, "new capture")
        XCTAssertTrue(fixture.outputs.isEmpty)
        XCTAssertTrue(fixture.errors.isEmpty)
        fixture.send("new capture final", final: true)
        let result = await newStop.value
        XCTAssertEqual(result.text, "new capture final")
        XCTAssertEqual(fixture.outputs.count, 1)
        XCTAssertEqual(fixture.releases, 2)
    }

}

@MainActor
private final class Fixture {
    let transcriber: iOSLiveTranscriber
    var callbacks: [(LegacyAppleRecognitionUpdate?, Error?) -> Void] = []
    var deadlines: [() -> Void] = []
    var finishing = XCTestExpectation(description: "finish requested")
    var operations: [String] = []
    var outputs: [TranscriptionResult] = []
    var errors: [Error] = []
    var releases = 0
    var deadlineCancellations = 0
    var onEndAudio: (() -> Void)?
    var starts: Int { callbacks.count }

    init(useRealDeadline: Bool = false) {
        let manager = AudioSessionManager()
        manager.configureRecording = {}
        self.transcriber = iOSLiveTranscriber(audioSessionManager: manager)
        manager.deactivateRecording = { [weak self] in self?.releases += 1 }
        self.transcriber.permissionCheck = { true }
        self.transcriber.modelID = AppleLocalModels.legacySpeechModelID
        self.transcriber.legacyRecognitionStart = { [unowned self] callback in
            self.callbacks.append(callback)
            return LegacyAppleRecognitionTask(
                endAudio: { [unowned self] in
                    self.operations.append("end")
                    self.onEndAudio?()
                },
                finish: { [unowned self] in
                    self.operations.append("finish")
                    self.finishing.fulfill()
                },
                cancel: { [unowned self] in self.operations.append("cancel") }
            )
        }
        if !useRealDeadline {
            self.transcriber.scheduleLegacyDeadline = { [unowned self] completion in
                self.deadlines.append(completion)
                return { [unowned self] in self.deadlineCancellations += 1 }
            }
        }
        self.transcriber.onFinalResult = { [unowned self] in self.outputs.append($0) }
        self.transcriber.onError = { [unowned self] in self.errors.append($0) }
    }

    func send(_ text: String, final: Bool, confidence: Double = 0.8) {
        self.callbacks.last?(Self.update(text, final: final, confidence: confidence), nil)
    }

    static func update(_ text: String, final: Bool, confidence: Double = 0.8) -> LegacyAppleRecognitionUpdate {
        LegacyAppleRecognitionUpdate(
            text: text, isFinal: final,
            segments: text.isEmpty ? [] : [TranscriptionSegment(
                startTime: 0, endTime: 1, text: text, isFinal: true, confidence: confidence
            )],
            confidence: text.isEmpty ? nil : confidence
        )
    }
}
#endif
