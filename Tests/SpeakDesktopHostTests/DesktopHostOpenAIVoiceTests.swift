import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakTestSupport
import XCTest

final class DesktopHostOpenAIVoiceTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var session: URLSession!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-openai-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        session = StubURLProtocol.makeSession()
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    func testNativeJourney_PreservesTupleSpeedExactWAVArchiveAndRetainedReplayExport() async throws {
        let voice = DesktopSpeechVoice.openai(.highDefinition, OpenAITTSCatalog.voices[0])
        await controller.selectVoiceOutput(voice)
        let saved = await controller.saveVoiceSynthesisOptions(try VoiceSynthesisOptions(speed: 1.5))
        XCTAssertTrue(saved)
        let source = try VoiceOutputSourceSnapshot(source: .typedText,
            text: String(repeating: "x", count: OpenAITTSAPI.maximumInputScalars + 1))
        let wav = try await generate(source: source, save: true)
        let settings = await controller.voiceOutputSettings()
        XCTAssertEqual(settings.controlsPresentation.capabilities, 1)
        XCTAssertEqual(settings.controlsPresentation.speed, 1.5)
        XCTAssertEqual(settings.pickerPresentation.labels[settings.pickerPresentation.selected], voice.label)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        let generated = await controller.generatedVoice
        let result = try XCTUnwrap(generated)
        XCTAssertEqual(result.audio.wav, wav)
        XCTAssertEqual(result.audio.sampleRate, 24_000)
        let owner = await controller.voiceOutputRecordID
        XCTAssertNil(owner)
        let archive = await controller.store.directory
        let files = try FileManager.default.contentsOfDirectory(at: archive,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" }
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first)), wav)
        let records = await controller.voiceUsage.records
        XCTAssertEqual(records?.map(\.inputCharacters), [4_096, 1])
        XCTAssertTrue(records?.allSatisfy { $0.historyRecordID == nil && $0.reportedInputTokens == nil } == true)
        FakeLog.shared.setKey("", name: voice.apiKeyIdentifier)
        await controller.selectVoiceOutput(.deepgram(DeepgramSpeechCatalog.voices[0]))
        await controller.playGeneratedVoice(result.id.uuidString)
        await controller.voiceGenerationTask?.value
        let destination = directory.deletingLastPathComponent().appendingPathComponent("openai-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: destination) }
        await controller.exportGeneratedVoice(result.id.uuidString, path: destination.path)
        await controller.readAloudState.exportTask?.value
        XCTAssertEqual(try Data(contentsOf: destination), wav)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 2)
        let after = await controller.voiceUsage.records
        XCTAssertEqual(after, records)
    }

    func testMiniUsage_ExposesUnknownTokenAudioChargesRealHistoryAttributionAndOptOut() async throws {
        await controller.selectVoiceOutput(.openai(.mini, OpenAITTSCatalog.voices[0]))
        let id = UUID()
        let source = try VoiceOutputSourceSnapshot(source: .history, text: "Synthetic History.", recordID: id)
        _ = try await generate(source: source)
        let records = await controller.voiceUsage.records
        let record = try XCTUnwrap(records?.first)
        XCTAssertEqual(record.historyRecordID, id)
        XCTAssertNotNil(record.audioDuration)
        XCTAssertNil(record.estimatedCostUSD)
        XCTAssertNil(record.reportedInputTokens)
        XCTAssertNil(record.estimatedInputCostUSD)
        XCTAssertNil(record.estimatedAudioCostUSD)
        await controller.showVoiceUsage(text: "Synthetic usage.", requestID: "openai-usage")
        let summary = await controller.voiceUsageSummary()
        XCTAssertTrue(summary.contains("OpenAI text/audio tokens and billing were not reported"))
        XCTAssertTrue(summary.contains("Charges are unestimated"))
        await controller.saveVoiceUsageTracking(false, requestID: "off")
        _ = try await generate(source: VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic opt-out."))
        let after = await controller.voiceUsage.records
        XCTAssertEqual(after, records)
        let generated = await controller.generatedVoice
        XCTAssertNil(generated?.source.recordID)
    }

    func testUnsupportedStoredControls_RemainVisibleAndRefuseBeforeKeyOrTransport() async throws {
        await controller.selectVoiceOutput(.openai(.standard, OpenAITTSCatalog.voices[0]))
        let saved = await controller.saveVoiceSynthesisOptions(try VoiceSynthesisOptions(pitch: 2, useSSML: true))
        XCTAssertTrue(saved)
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic refusal.")
        _ = try await generate(source: source)
        let settings = await controller.voiceOutputSettings()
        XCTAssertEqual(settings.pitch, 2)
        XCTAssertEqual(settings.useSSML, true)
        XCTAssertEqual(settings.controlsPresentation.capabilities, 1)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        let generated = await controller.generatedVoice
        XCTAssertNil(generated)
    }

    func testStopAndClose_CancelOwnedOpenAIRequestWithoutPartialPublicationOrPlayback() async throws {
        let started = expectation(description: "OpenAI request started")
        StubURLProtocol.handler = { _ in .hang }
        StubURLProtocol.onStartLoading = { started.fulfill() }
        let voice = DesktopSpeechVoice.openai(.mini, OpenAITTSCatalog.voices[0])
        await controller.selectVoiceOutput(voice)
        FakeLog.shared.setKey("synthetic-key", name: voice.apiKeyIdentifier)
        let source = try VoiceOutputSourceSnapshot(source: .history,
            text: String(repeating: "x", count: OpenAITTSAPI.maximumInputScalars + 1), recordID: UUID())
        try await admit(source: source)
        await fulfillment(of: [started], timeout: 3)
        let owner = await controller.voiceOutputRecordID
        XCTAssertEqual(owner, source.recordID)
        let task = await controller.voiceGenerationTask
        await controller.playbackStop()
        await task?.value
        let result = await controller.generatedVoice
        XCTAssertNil(result)
        let cleared = await controller.voiceOutputRecordID
        XCTAssertNil(cleared)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        let records = await controller.voiceUsage.records
        XCTAssertEqual(records?.map(\.outcome), [.cancelled])
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        let report = await controller.close()
        XCTAssertEqual(report.unfinishedOperations, 0)
    }

    private func generate(source: VoiceOutputSourceSnapshot, save: Bool = false) async throws -> Data {
        let pcm = Data(repeating: 1, count: 480)
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 24_000))
        StubURLProtocol.handler = { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            return .respond(response, wav)
        }
        FakeLog.shared.setKey("synthetic-key", name: OpenAITTSCatalog.credentialIdentifier)
        try await admit(source: source, save: save)
        await controller.voiceGenerationTask?.value
        let count = try OpenAITTSAPI.synthesisSegments(source.text).count
        return try XCTUnwrap(PCMWaveWriter.wavData(
            pcm: Data((0..<count).flatMap { _ in Array(pcm) }), sampleRate: 24_000))
    }

    private func admit(source: VoiceOutputSourceSnapshot, save: Bool = false) async throws {
        let transport = try XCTUnwrap(session)
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: true, saveToRecordings: save)
        ) { snapshot, selection, credential in
            try await DesktopSpeechSynthesis(session: transport).synthesize(
                snapshot, voice: selection.voice, options: selection.options, credential: credential)
        }
    }
}
