import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

final class DesktopHostGroqVoiceTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var session: URLSession!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-groq-\(UUID())")
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

    func testGeneration_RealFactoryPlaysRetainsExportsAndKeepsTruthfulCharacterEstimates() async throws {
        let wav = try await generate()
        let voice = DesktopSpeechVoice.groq(GroqTTSCatalog.defaultVoice)
        let settings = await controller.voiceOutputSettings()
        XCTAssertEqual(settings.controlsPresentation.capabilities, 0)
        XCTAssertEqual(settings.pickerPresentation.labels[settings.pickerPresentation.selected], voice.label)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        let owner = await controller.voiceOutputRecordID
        XCTAssertNil(owner)
        let usage = await controller.voiceUsage
        let records = try XCTUnwrap(usage.records)
        XCTAssertEqual(records.map(\.inputCharacters), [250, 5])
        XCTAssertTrue(records.allSatisfy { $0.historyRecordID == nil && $0.reportedInputTokens == nil })
        XCTAssertEqual(records.reduce(Decimal(0)) { $0 + ($1.estimatedCostUSD ?? 0) },
                       Decimal(204) * GroqTTSCatalog.defaultVoice.model.costPerThousandCharacters / 1_000)
        let summary = await controller.voiceUsageSummary()
        XCTAssertTrue(summary.contains("not charges"))
        XCTAssertTrue(summary.contains(GroqTTSCatalog.pricingEstimateBasis))
        let generated = await controller.generatedVoice
        let result = try XCTUnwrap(generated)
        XCTAssertEqual(result.audio.wav, wav)
        FakeLog.shared.setKey("", name: voice.apiKeyIdentifier)
        await controller.selectVoiceOutput(.deepgram(DeepgramSpeechCatalog.voices[0]))
        await controller.playGeneratedVoice(result.id.uuidString)
        await controller.voiceGenerationTask?.value
        let destination = directory.deletingLastPathComponent().appendingPathComponent("groq-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: destination) }
        await controller.exportGeneratedVoice(result.id.uuidString, path: destination.path)
        await controller.readAloudState.exportTask?.value
        XCTAssertEqual(try Data(contentsOf: destination), wav)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 2)
        let finalRecords = await controller.voiceUsage.records
        XCTAssertEqual(finalRecords, records)
        let restored = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await restored.showVoiceUsage(text: "Synthetic restored estimate.", requestID: "restored")
        let loaded = await restored.voiceUsage.records
        XCTAssertEqual(loaded, records)
        await restored.close()
    }

    func testOptOut_RealGroqSynthesisDoesNotKeepALedger() async throws {
        await controller.saveVoiceUsageTracking(false, requestID: "off")
        _ = try await generate()
        let usage = await controller.voiceUsage
        XCTAssertTrue(usage.records?.isEmpty ?? true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("VoiceUsage").path))
    }

    func testHistorySource_RealFactoryKeepsTheCapturedHistoryOwnerAcrossRequests() async throws {
        let owner = UUID()
        let source = try VoiceOutputSourceSnapshot(source: .history,
            text: String(repeating: "x", count: 201), recordID: owner)
        _ = try await generate(source: source)
        let generated = await controller.generatedVoice
        XCTAssertEqual(generated?.source.recordID, owner)
        let records = await controller.voiceUsage.records
        XCTAssertEqual(records?.count, 2)
        XCTAssertTrue(records?.allSatisfy { $0.historyRecordID == owner } == true)
    }

    func testStopAndClose_RealTransportCancellationClearsOwnerWithoutPublishingAudio() async throws {
        let started = expectation(description: "Groq request admitted")
        StubURLProtocol.handler = { _ in .hang }
        StubURLProtocol.onStartLoading = { started.fulfill() }
        let voice = DesktopSpeechVoice.groq(GroqTTSCatalog.defaultVoice)
        FakeLog.shared.setKey("synthetic-key", name: voice.apiKeyIdentifier)
        await controller.selectVoiceOutput(voice)
        let source = try VoiceOutputSourceSnapshot(source: .history,
            text: String(repeating: "x", count: 201), recordID: UUID())
        let transport = try XCTUnwrap(session)
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: true, saveToRecordings: false)
        ) { snapshot, selection, credential in
            try await DesktopSpeechSynthesis(session: transport).synthesize(
                snapshot, voice: selection.voice, options: selection.options, credential: credential)
        }
        await fulfillment(of: [started], timeout: 3)
        let capturedOwner = await controller.voiceOutputRecordID
        XCTAssertEqual(capturedOwner, source.recordID)
        let task = await controller.voiceGenerationTask
        await controller.playbackStop()
        await task?.value
        let generated = await controller.generatedVoice
        XCTAssertNil(generated)
        let activeOwner = await controller.voiceOutputRecordID
        XCTAssertNil(activeOwner)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
        let records = await controller.voiceUsage.records
        XCTAssertEqual(records?.map(\.outcome), [.cancelled])
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        let report = await controller.close()
        XCTAssertEqual(report.unfinishedOperations, 0)
    }

    private func generate(source supplied: VoiceOutputSourceSnapshot? = nil) async throws -> Data {
        let pcm = Data(repeating: 1, count: 480)
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 24_000))
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/wav"])), wav)
        }
        let voice = DesktopSpeechVoice.groq(GroqTTSCatalog.defaultVoice)
        FakeLog.shared.setKey("synthetic-key", name: voice.apiKeyIdentifier)
        await controller.selectVoiceOutput(voice)
        let source = try supplied ?? VoiceOutputSourceSnapshot(
            source: .typedText, text: String(repeating: "cafe\u{301}", count: 51))
        let transport = try XCTUnwrap(session)
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: true, saveToRecordings: false)
        ) { snapshot, selection, credential in
            try await DesktopSpeechSynthesis(session: transport).synthesize(
                snapshot, voice: selection.voice, options: selection.options, credential: credential)
        }
        await controller.voiceGenerationTask?.value
        await controller.showVoiceUsage(text: source.text, requestID: "synthetic-groq-usage")
        let count = try GroqTTSAPI.synthesisSegments(source.text).count
        return try XCTUnwrap(PCMWaveWriter.wavData(
            pcm: Data((0..<count).flatMap { _ in Array(pcm) }), sampleRate: 24_000))
    }
}
