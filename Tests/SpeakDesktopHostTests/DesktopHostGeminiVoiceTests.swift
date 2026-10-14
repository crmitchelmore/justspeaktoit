import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

final class DesktopHostGeminiVoiceTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var session: URLSession!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-gemini-\(UUID())")
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

    func testGeneration_RealFactoryPlaysRetainsAndExportsWithoutAnotherRequestOrHistoryOwner() async throws {
        let wav = try await generate(tokens: 321)
        let voice = DesktopSpeechVoice.gemini(GeminiTTSCatalog.defaultVoice)
        let settings = await controller.voiceOutputSettings()
        XCTAssertEqual(settings.controlsPresentation.capabilities, 0)
        XCTAssertEqual(settings.pickerPresentation.labels[settings.pickerPresentation.selected], voice.label)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        let owner = await controller.voiceOutputRecordID
        XCTAssertNil(owner)
        let usage = await controller.voiceUsage
        XCTAssertEqual(usage.records?.first?.reportedInputTokens, 321)
        XCTAssertNil(usage.records?.first?.historyRecordID)
        let summary = await controller.voiceUsageSummary()
        XCTAssertTrue(summary.contains("Gemini reported text-input tokens: 321 across 1 requests"))
        XCTAssertTrue(summary.contains("not charges"))
        XCTAssertTrue(summary.contains(GeminiTTSCatalog.pricingEstimateBasis))
        let generated = await controller.generatedVoice
        let result = try XCTUnwrap(generated)
        XCTAssertEqual(result.audio.wav, wav)
        FakeLog.shared.setKey("", name: voice.apiKeyIdentifier)
        await controller.selectVoiceOutput(.deepgram(DeepgramSpeechCatalog.voices[0]))
        await controller.playGeneratedVoice(result.id.uuidString)
        await controller.voiceGenerationTask?.value
        let destination = directory.deletingLastPathComponent().appendingPathComponent("gemini-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: destination) }
        await controller.exportGeneratedVoice(result.id.uuidString, path: destination.path)
        await controller.readAloudState.exportTask?.value
        XCTAssertEqual(try Data(contentsOf: destination), wav)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        let finalUsage = await controller.voiceUsage.records
        XCTAssertEqual(finalUsage, usage.records)
    }

    func testMissingTokens_NativeUsageLeavesInputAndTotalUnknownButKeepsAudioComponent() async throws {
        _ = try await generate(tokens: nil)
        let usage = await controller.voiceUsage
        XCTAssertNil(usage.records?.first?.reportedInputTokens)
        XCTAssertNil(usage.records?.first?.estimatedInputCostUSD)
        XCTAssertNil(usage.records?.first?.estimatedCostUSD)
        XCTAssertNotNil(usage.records?.first?.estimatedAudioCostUSD)
        let summary = await controller.voiceUsageSummary()
        XCTAssertTrue(summary.contains("Input estimate: unknown until Gemini reports text-input tokens"))
        XCTAssertTrue(summary.contains("Tokens not reported on 1 requests"))
        XCTAssertTrue(summary.contains("Unknown input/total cost on 1 validated requests"))
        XCTAssertTrue(summary.contains("Unpriced requests excluded: 1"))
        let data = try Data(contentsOf: directory.appendingPathComponent("VoiceUsage/requests.json"))
        XCTAssertFalse(try XCTUnwrap(String(data: data, encoding: .utf8)).contains("Synthetic Gemini native"))
        let restored = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await restored.showVoiceUsage(text: "Synthetic fresh estimate.", requestID: "restored")
        let loaded = await restored.voiceUsage.records
        XCTAssertEqual(loaded, usage.records)
        await restored.close()
    }

    func testOptOut_RealSynthesisStillWorksWithoutKeepingTokensOrLedger() async throws {
        await controller.saveVoiceUsageTracking(false, requestID: "off")
        _ = try await generate(tokens: 321)
        let usage = await controller.voiceUsage
        XCTAssertTrue(usage.records?.isEmpty ?? true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("VoiceUsage").path))
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    private func generate(tokens: Int?) async throws -> Data {
        let pcm = Data(repeating: 1, count: 480)
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: GeminiTTSAPI.defaultSampleRate))
        var body: [String: Any] = ["steps": [["content": [[
            "type": "audio", "data": pcm.base64EncodedString(),
            "mime_type": "audio/l16", "sample_rate": 24_000, "channels": 1
        ]]]]]
        if let tokens { body["usage"] = ["input_tokens": tokens] }
        let response = try JSONSerialization.data(withJSONObject: body)
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])), response)
        }
        let voice = DesktopSpeechVoice.gemini(GeminiTTSCatalog.defaultVoice)
        FakeLog.shared.setKey("synthetic-key", name: voice.apiKeyIdentifier)
        await controller.selectVoiceOutput(voice)
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic Gemini native journey.")
        let transport = try XCTUnwrap(session)
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: true, saveToRecordings: false)
        ) { snapshot, selection, credential in
            try await DesktopSpeechSynthesis(session: transport).synthesize(
                snapshot, voice: selection.voice, options: selection.options, credential: credential)
        }
        await controller.voiceGenerationTask?.value
        await controller.showVoiceUsage(text: source.text, requestID: "synthetic-gemini-usage")
        return wav
    }
}
