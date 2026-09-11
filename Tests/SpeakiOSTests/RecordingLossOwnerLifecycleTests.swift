#if os(iOS)
import AVFoundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

/// Exercises actual adapter start/stop/cancel methods. Only microphone/provider
/// setup is injected; the writer, warning callback and final drain are real.
@MainActor
final class RecordingLossOwnerLifecycleTests: XCTestCase {
    // One continuous lifecycle proves delayed notifications cannot cross runs.
    // swiftlint:disable:next function_body_length
    func testAllOwners_startStopCancelRestartRetainFinalWriterTruth() async throws {
        for kind in ["legacy", "analyser", "openai", "shared", "batch"] {
            let owner = try makeOwner(kind)
            var warnings: [String] = []
            owner.reporting.onWarning = { warnings.append($0) }
            try await owner.start()
            let firstRun = owner.reporting.currentReport
            let firstURL = try XCTUnwrap(owner.recorder.currentFileURL)
            defer { try? FileManager.default.removeItem(at: firstURL) }
            let lateCallback = try XCTUnwrap(owner.recorder.onPersistenceIssue)
            let buffer = try makeBuffer()
            let written = expectation(description: "initial audio retained")
            owner.recorder.didWriteBufferHook = { _ in written.fulfill() }
            owner.recorder.writeBuffer(buffer)
            await fulfillment(of: [written], timeout: 2)
            owner.recorder.didWriteBufferHook = nil
            owner.recorder.beforeFileWrite = { throw CocoaError(.fileWriteOutOfSpace) }
            for _ in 0..<4 { owner.recorder.writeBuffer(buffer) }
            for _ in 0..<100 where owner.reporting.currentReport.snapshot.persistence.isComplete {
                try await Task.sleep(for: .milliseconds(10))
            }
            owner.reporting.deliverWarningIfNeeded()
            owner.reporting.deliverWarningIfNeeded()
            XCTAssertEqual(warnings.count, 1, kind)
            let result = try await owner.stop()
            XCTAssertGreaterThan(firstRun.snapshot.persistence.writeFailures, 0, kind)
            XCTAssertNotNil(owner.reporting.finalSummary, kind)
            XCTAssertEqual(firstRun.snapshot.rejectedBuffers, 0)
            if kind == "shared" || kind == "batch" {
                XCTAssertEqual(result.text, "Available words", kind)
            }
            if kind == "batch" {
                XCTAssertTrue(
                    owner.reporting.finalSummary?.contains("Batch transcription may also be incomplete") == true
                )
            }

            owner.recorder.beforeFileWrite = nil
            try await owner.start()
            let cancelledURL = try XCTUnwrap(owner.recorder.currentFileURL)
            owner.cancel()
            try await owner.start() // shared adapter awaits its existing cleanup task
            XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledURL.path), kind)
            let nextURL = try XCTUnwrap(owner.recorder.currentFileURL)
            defer { try? FileManager.default.removeItem(at: nextURL) }
            lateCallback(firstRun.snapshot.persistence)
            owner.reporting.deliverWarningIfNeeded()
            XCTAssertEqual(warnings.count, 1, "An old run cannot warn the replacement: \(kind)")
            owner.recorder.writeBuffer(buffer)
            _ = try await owner.stop()
            XCTAssertNil(owner.reporting.finalSummary, kind)
            XCTAssertTrue(owner.recorder.lastDiagnostics?.isComplete == true)
        }
    }

    func testForegroundCancelRetiresVisibleLossNotice() {
        let coordinator = TranscriberCoordinator()
        coordinator.handleRecordingWarning("Some microphone audio was missed.")
        XCTAssertNotNil(coordinator.recordingWarning)
        coordinator.cancel()
        XCTAssertNil(coordinator.recordingWarning)
    }

    private struct Owner {
        let recorder: AudioRecordingPersistence
        let reporting: RecordingLossReporting
        let start: () async throws -> Void
        let stop: () async throws -> TranscriptionResult
        let cancel: () -> Void
    }

    // The matrix keeps each real owner's lifecycle bindings together.
    // swiftlint:disable:next function_body_length
    private func makeOwner(_ kind: String) throws -> Owner {
        let manager = AudioSessionManager()
        manager.permissionStatus = { true }
        manager.configureRecording = {}
        manager.deactivateRecording = {}
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        switch kind {
        case "legacy", "analyser":
            let transcriber = iOSLiveTranscriber(audioSessionManager: manager)
            transcriber.permissionCheck = { true }
            transcriber.modelID = kind == "legacy"
                ? AppleLocalModels.legacySpeechModelID : AppleLocalModels.preferredSpeechModelID
            let startWriter = { [unowned transcriber] in
                transcriber.recordingLoss.startWriter(transcriber.audioRecorder, format: format)
            }
            transcriber.legacyStart = startWriter
            transcriber.analyzerStart = startWriter
            return Owner(recorder: transcriber.audioRecorder, reporting: transcriber.recordingLoss,
                         start: { try await transcriber.start() }, stop: { await transcriber.stop() },
                         cancel: transcriber.cancel)
        case "openai":
            let transcriber = OpenAIRealtimeLiveTranscriber(audioSessionManager: manager)
            transcriber.configure(apiKey: "test")
            transcriber.startCaptureAudio = { [unowned transcriber] in
                transcriber.recordingLoss.startWriter(transcriber.audioRecorder, format: format)
            }
            return Owner(recorder: transcriber.audioRecorder, reporting: transcriber.recordingLoss,
                         start: transcriber.start, stop: { await transcriber.stop() }, cancel: transcriber.cancel)
        case "shared":
            let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: "deepgram/nova-3-streaming"))
            let transcriber = SharedClientLiveTranscriber(route: route, apiKey: "test", audioSessionManager: manager)
            transcriber.clientFactory = { LossReportingClient() }
            transcriber.startCaptureAudio = { [unowned transcriber] in
                transcriber.recordingLoss.startWriter(transcriber.audioRecorder, format: format)
            }
            transcriber.onError = { _ in XCTFail("Writer failure interrupted healthy live transcription") }
            return Owner(recorder: transcriber.audioRecorder, reporting: transcriber.recordingLoss,
                         start: transcriber.start, stop: { await transcriber.stop() }, cancel: transcriber.cancel)
        default:
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [LossReportingURLProtocol.self]
            let transcriber = IOSBatchTranscriber(
                audioSessionManager: manager, model: "openai/gpt-4o-mini-transcribe", apiKey: "test",
                session: URLSession(configuration: configuration)
            )
            transcriber.startCaptureAudio = { [unowned transcriber] in
                transcriber.recordingLoss.startWriter(transcriber.audioRecorder, format: format)
            }
            return Owner(recorder: transcriber.audioRecorder, reporting: transcriber.recordingLoss,
                         start: transcriber.start, stop: { try await transcriber.stop(language: nil) },
                         cancel: transcriber.cancel)
        }
    }

    private func makeBuffer() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        if let samples = buffer.floatChannelData?[0] { samples.initialize(repeating: 0, count: 4_800) }
        return buffer
    }
}

private final class LossReportingClient: FinalizingStreamingTranscriptionClient {
    let finalShape: TranscriptFinalShape = .standaloneSegments
    let finishFlushesBufferedAudio = true
    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {}
    func sendAudio(_ audioData: Data) {}
    func stop() {}
    func finishAndWait() async -> String? { "Available words" }
}

private final class LossReportingURLProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"text\":\"Available words\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
