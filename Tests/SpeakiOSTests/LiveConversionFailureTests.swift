#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore
import XCTest
@testable import SpeakiOSLib

/// Lost capture audio must reach the iOS session owner once per run, keep the
/// text already transcribed, and never leak into a replacement run.
@MainActor
final class LiveConversionFailureTests: XCTestCase {
    private let failure = LivePCMConversionError.conversionFailed(domain: NSOSStatusErrorDomain, code: -50)

    func testProcessor_reportsTheFirstFailureOnceAndSendsNothingUnconverted() throws {
        let processor = LiveTapPCMProcessor(queueLabel: "test.conversion", poolLabel: "test")
        let input = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 480))
        buffer.frameLength = 480
        // No Apple converter encodes MP3.
        let unconvertible = try XCTUnwrap(AVAudioFormat(settings: [
            AVFormatIDKey: kAudioFormatMPEGLayer3, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1
        ]))
        let sent = Counter(), reports = Counter()
        let run = makeRun(output: unconvertible, sent: sent, reports: reports)

        processor.convertAndSend(buffer, run: run)
        processor.convertAndSend(buffer, run: run)

        XCTAssertEqual(reports.value, 1)
        XCTAssertEqual(sent.value, 0, "Nothing unconverted reaches the provider")
        processor.finishRun()
    }

    func testProcessor_sendsPCM16AtTheProviderRate() throws {
        let processor = LiveTapPCMProcessor(queueLabel: "test.conversion", poolLabel: "test")
        let input = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let output = try XCTUnwrap(processor.prepareOutputFormat(from: input, sampleRate: 24_000))
        XCTAssertEqual(output.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(output.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        let sent = Counter(), reports = Counter()
        processor.convertAndSend(buffer, run: makeRun(output: output, sent: sent, reports: reports))
        XCTAssertGreaterThan(sent.value, 0)
        XCTAssertEqual(reports.value, 0)
        processor.finishRun()
    }

    func testSharedClient_failsTheRunOnceKeepsTextAndIgnoresARetiredRun() async throws {
        let manager = AudioSessionManager()
        manager.permissionStatus = { true }
        manager.configureRecording = {}
        manager.deactivateRecording = {}
        let route = try XCTUnwrap(LiveTranscriptionRouting.route(for: "deepgram/nova-3-streaming"))
        let transcriber = SharedClientLiveTranscriber(route: route, apiKey: "test-key", audioSessionManager: manager)
        transcriber.startCaptureAudio = {}
        let client = CleanupTestClient()
        transcriber.clientFactory = { client }
        var errors: [Error] = []
        transcriber.onError = { errors.append($0) }

        try await transcriber.start()
        client.transcript?("Kept words.", true)
        let report = try XCTUnwrap(transcriber.conversionFailure)
        report(failure)
        report(failure)
        await settle { !errors.isEmpty }

        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(errors.first as? LivePCMConversionError, failure)
        XCTAssertEqual(transcriber.partialText, "Kept words.")
        let result = await transcriber.stop()
        XCTAssertEqual(result.text, "Kept words.", "Recovery text survives the failed run")
        XCTAssertEqual(transcriber.error as? LivePCMConversionError, failure)
        XCTAssertEqual(errors.count, 1, "Stop does not report the same failure again")

        let replacement = CleanupTestClient()
        transcriber.clientFactory = { replacement }
        try await transcriber.start()
        let retired = try XCTUnwrap(transcriber.conversionFailure)
        transcriber.cancel()
        await transcriber.awaitCancellationSettled()
        try await transcriber.start()
        retired(failure)
        await settle { false }
        XCTAssertEqual(errors.count, 1, "A retired run's failure never reaches its replacement")
        XCTAssertNil(transcriber.error)
        transcriber.cancel()
    }

    func testOpenAI_failsTheRunOnceKeepsTextAndIgnoresARetiredRun() async throws {
        var socket: OverflowTestSocket?
        let transcriber = OpenAIRealtimeLiveTranscriber(
            audioSessionManager: AudioSessionManager(),
            makeClient: {
                let connection = OverflowTestSocket()
                socket = connection
                return OpenAIRealtimeWebSocketClient(
                    apiKey: "synthetic-test-key", model: "gpt-live-transcribe", language: nil, sampleRate: 24_000,
                    makeConnection: { _ in connection }
                )
            },
            startCapture: { _ in }
        )
        transcriber.configure(apiKey: "synthetic-test-key")
        var errors: [Error] = []
        transcriber.onError = { errors.append($0) }

        try await transcriber.start()
        try XCTUnwrap(socket).emit([
            "type": "conversation.item.input_audio_transcription.delta", "item_id": "kept", "delta": "Kept words."
        ])
        await settle { !transcriber.partialText.isEmpty }
        let report = try XCTUnwrap(transcriber.conversionFailure)
        report(failure)
        report(failure)
        await settle { !errors.isEmpty }

        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(transcriber.error as? LivePCMConversionError, failure)
        XCTAssertEqual(transcriber.partialText, "Kept words.")

        transcriber.cancel()
        try await transcriber.start()
        let retired = try XCTUnwrap(transcriber.conversionFailure)
        transcriber.cancel()
        try await transcriber.start()
        retired(failure)
        await settle { false }
        XCTAssertEqual(errors.count, 1, "A retired run's failure never reaches its replacement")
        XCTAssertNil(transcriber.error)
        transcriber.cancel()
    }

    private func makeRun(output: AVAudioFormat, sent: Counter, reports: Counter) -> LiveTapPCMProcessor.Run {
        LiveTapPCMProcessor.Run(
            recorder: AudioRecordingPersistence(),
            lossReport: RecordingLossReport(),
            outputFormat: output,
            onInput: {},
            send: { _ in sent.increment() },
            onConversionFailure: LivePCMConversionFailureReport { _ in reports.increment() }
        )
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<100 where !done() { await Task.yield() }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
#endif
