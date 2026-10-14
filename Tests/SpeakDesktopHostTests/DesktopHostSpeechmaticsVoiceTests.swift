import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

final class DesktopHostSpeechmaticsVoiceTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var session: URLSession!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-speechmatics-\(UUID())")
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

    func testGeneration_PlaysArchivesRetainsAndExportsExactRateWithoutNewRequests() async throws {
        let wav = try await generate(save: true)
        let settings = await controller.voiceOutputSettings()
        let voice = DesktopSpeechVoice.speechmatics(SpeechmaticsTTSCatalog.defaultVoice)
        XCTAssertEqual(settings.controlsPresentation.capabilities, 0)
        XCTAssertEqual(settings.pickerPresentation.labels[settings.pickerPresentation.selected], voice.label)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        let generated = await controller.generatedVoice
        let result = try XCTUnwrap(generated)
        XCTAssertEqual(result.audio.wav, wav)
        XCTAssertEqual(result.audio.sampleRate, 16_000)
        XCTAssertEqual(result.audio.duration, 0.03, accuracy: 0.000001)
        let owner = await controller.voiceOutputRecordID
        XCTAssertNil(owner)
        let recordingsDirectory = await controller.store.directory
        let archived = try FileManager.default.contentsOfDirectory(at: recordingsDirectory,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "wav" }
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(archived.first)), wav)
        let records = await controller.voiceUsage.records
        XCTAssertEqual(records?.map(\.inputCharacters), [DeepgramSpeechRequest.maximumCharacters, 1])
        XCTAssertTrue(records?.allSatisfy { $0.historyRecordID == nil && $0.reportedInputTokens == nil } == true)
        FakeLog.shared.setKey("", name: voice.apiKeyIdentifier)
        await controller.selectVoiceOutput(.deepgram(DeepgramSpeechCatalog.voices[0]))
        await controller.playGeneratedVoice(result.id.uuidString)
        await controller.voiceGenerationTask?.value
        let destination = directory.deletingLastPathComponent().appendingPathComponent("speechmatics-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: destination) }
        await controller.exportGeneratedVoice(result.id.uuidString, path: destination.path)
        await controller.readAloudState.exportTask?.value
        XCTAssertEqual(try Data(contentsOf: destination), wav)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 2)
        let finalRecords = await controller.voiceUsage.records
        XCTAssertEqual(finalRecords, records)
    }

    func testHistoryOwnerAndOptOut_PreserveRealAttributionWithoutAnotherLedgerAuthority() async throws {
        let owner = UUID()
        let source = try VoiceOutputSourceSnapshot(source: .history, text: "Synthetic History.", recordID: owner)
        _ = try await generate(source: source)
        let generated = await controller.generatedVoice
        XCTAssertEqual(generated?.source.recordID, owner)
        let records = await controller.voiceUsage.records
        XCTAssertEqual(records?.first?.historyRecordID, owner)
        await controller.saveVoiceUsageTracking(false, requestID: "off")
        _ = try await generate()
        let after = await controller.voiceUsage.records
        XCTAssertEqual(after, records)
        let other = await controller.generatedVoice
        XCTAssertNil(other?.source.recordID)
    }

    func testStopAndClose_CancelTransportBeforePublishingOrPlayingAnyPartialAudio() async throws {
        let started = expectation(description: "Speechmatics request admitted")
        StubURLProtocol.handler = { _ in .hang }
        StubURLProtocol.onStartLoading = { started.fulfill() }
        let voice = DesktopSpeechVoice.speechmatics(SpeechmaticsTTSCatalog.defaultVoice)
        FakeLog.shared.setKey("synthetic-key", name: voice.apiKeyIdentifier)
        await controller.selectVoiceOutput(voice)
        let source = try VoiceOutputSourceSnapshot(source: .history,
            text: String(repeating: "x", count: DeepgramSpeechRequest.maximumCharacters + 1), recordID: UUID())
        let transport = try XCTUnwrap(session)
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: true, saveToRecordings: true)
        ) { snapshot, selection, credential in
            try await DesktopSpeechSynthesis(session: transport).synthesize(
                snapshot, voice: selection.voice, options: selection.options, credential: credential)
        }
        await fulfillment(of: [started], timeout: 3)
        let captured = await controller.voiceOutputRecordID
        XCTAssertEqual(captured, source.recordID)
        let task = await controller.voiceGenerationTask
        await controller.playbackStop()
        await task?.value
        let generated = await controller.generatedVoice
        XCTAssertNil(generated)
        let cleared = await controller.voiceOutputRecordID
        XCTAssertNil(cleared)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        let records = await controller.voiceUsage.records
        XCTAssertEqual(records?.map(\.outcome), [.cancelled])
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        let report = await controller.close()
        XCTAssertEqual(report.unfinishedOperations, 0)
    }

    private func generate(source supplied: VoiceOutputSourceSnapshot? = nil, save: Bool = false) async throws -> Data {
        let pcm = Data(repeating: 1, count: 480)
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 16_000))
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/wav"])), wav)
        }
        let voice = DesktopSpeechVoice.speechmatics(SpeechmaticsTTSCatalog.defaultVoice)
        FakeLog.shared.setKey("synthetic-key", name: voice.apiKeyIdentifier)
        await controller.selectVoiceOutput(voice)
        let source = try supplied ?? VoiceOutputSourceSnapshot(source: .typedText,
            text: String(repeating: "x", count: DeepgramSpeechRequest.maximumCharacters + 1))
        let transport = try XCTUnwrap(session)
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: true, saveToRecordings: save)
        ) { snapshot, selection, credential in
            try await DesktopSpeechSynthesis(session: transport).synthesize(
                snapshot, voice: selection.voice, options: selection.options, credential: credential)
        }
        await controller.voiceGenerationTask?.value
        let count = SpeechTextSegmenter.segments(source.text).count
        return try XCTUnwrap(PCMWaveWriter.wavData(
            pcm: Data((0..<count).flatMap { _ in Array(pcm) }), sampleRate: 16_000))
    }
}
