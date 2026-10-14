import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

final class DesktopHostCartesiaVoiceTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var session: URLSession!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-cartesia-\(UUID())")
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

    func testGeneration_RealFactoryPlaysAndRetainsWAVWithCanonicalControlsAndUsage() async throws {
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 1, count: 480), sampleRate: 24_000))
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/wav"])), wav)
        }
        let voice = DesktopSpeechVoice.cartesia(CartesiaTTSCatalog.defaultVoice)
        FakeLog.shared.setKey("synthetic-key", name: voice.apiKeyIdentifier)
        await controller.selectVoiceOutput(voice)
        let saved = await controller.saveVoiceSynthesisOptions(try VoiceSynthesisOptions(speed: 1.25))
        XCTAssertTrue(saved)
        let settings = await controller.voiceOutputSettings()
        XCTAssertEqual(settings.controlsPresentation.minimumSpeed, CartesiaTTSAPI.speedRange.lowerBound)
        XCTAssertEqual(settings.controlsPresentation.maximumSpeed, CartesiaTTSAPI.speedRange.upperBound)
        XCTAssertEqual(settings.controlsPresentation.capabilities, 1)
        XCTAssertEqual(settings.pickerPresentation.labels[settings.pickerPresentation.selected], voice.label)
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic Cartesia native journey.")
        let transport = try XCTUnwrap(session)
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: true, saveToRecordings: false)
        ) { snapshot, selection, credential in
            try await DesktopSpeechSynthesis(session: transport).synthesize(
                snapshot, voice: selection.voice, options: selection.options, credential: credential)
        }
        await controller.voiceGenerationTask?.value
        let generated = await controller.generatedVoice
        let result = try XCTUnwrap(generated)
        XCTAssertEqual(result.audio.wav, wav)
        XCTAssertEqual(result.voice, voice)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        let owner = await controller.voiceOutputRecordID
        XCTAssertNil(owner)
        let usage = await controller.voiceUsage
        XCTAssertEqual(usage.records?.count, 1)
        XCTAssertEqual(usage.records?.first?.modelID, voice.modelID)
        XCTAssertNil(usage.records?.first?.historyRecordID)
        await controller.showVoiceUsage(text: source.text, requestID: "synthetic-cartesia-usage")
        let summary = await controller.voiceUsageSummary()
        XCTAssertTrue(summary.contains(CartesiaTTSAPI.pricingEstimateBasis))
        XCTAssertTrue(summary.contains("not charges"))
        try await verifyRetainedExport(result, voice: voice, wav: wav)
    }

    private func verifyRetainedExport(
        _ result: DesktopGeneratedVoiceResult, voice: DesktopSpeechVoice, wav: Data
    ) async throws {
        FakeLog.shared.setKey("", name: voice.apiKeyIdentifier)
        await controller.selectVoiceOutput(.deepgram(DeepgramSpeechCatalog.voices[0]))
        await controller.playGeneratedVoice(result.id.uuidString)
        await controller.voiceGenerationTask?.value
        let destination = directory.deletingLastPathComponent()
            .appendingPathComponent("synthetic-cartesia-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: destination) }
        await controller.exportGeneratedVoice(result.id.uuidString, path: destination.path)
        await controller.readAloudState.exportTask?.value
        XCTAssertEqual(try Data(contentsOf: destination), wav)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }
}
