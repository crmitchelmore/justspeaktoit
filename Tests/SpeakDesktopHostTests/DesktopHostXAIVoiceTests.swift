import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

final class DesktopHostXAIVoiceTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        DesktopHostModels.configure(streamingQualified: false)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-xai-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects(),
                                                             shutdownGrace: .milliseconds(60))
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        try? FileManager.default.removeItem(at: directory)
        DesktopHostModels.configure(streamingQualified: true)
    }

    func testGeneration_RealFactoryPublishesReplayableExportWithCanonicalControlsAndNoHistoryOwner() async throws {
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel(); StubURLProtocol.reset() }
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 1, count: 480), sampleRate: 24_000))
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/wav"])), wav)
        }
        let voice = DesktopSpeechVoice.xai(XAITTSCatalog.voices[0])
        FakeLog.shared.setKey("synthetic-key", name: voice.apiKeyIdentifier)
        await controller.selectVoiceOutput(voice)
        let saved = await controller.saveVoiceSynthesisOptions(try VoiceSynthesisOptions(speed: 1.25))
        XCTAssertTrue(saved)
        let settings = await controller.voiceOutputSettings()
        XCTAssertEqual(settings.controlsPresentation.minimumSpeed, XAITTSAPI.speedRange.lowerBound)
        XCTAssertEqual(settings.controlsPresentation.maximumSpeed, XAITTSAPI.speedRange.upperBound)
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic native xAI journey.")
        await controller.generateVoiceSource(
            source, options: .init(autoPlay: true, saveToRecordings: false)
        ) { snapshot, selection, credential in
            try await DesktopSpeechSynthesis(session: session).synthesize(
                snapshot, voice: selection.voice, options: selection.options, credential: credential)
        }
        await finish()
        let generated = await controller.generatedVoice
        let result = try XCTUnwrap(generated)
        XCTAssertEqual(result.audio.wav, wav)
        XCTAssertEqual(result.voice, voice)
        XCTAssertEqual(result.options.speed, 1.25)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        let owner = await controller.voiceOutputRecordID
        XCTAssertNil(owner)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        FakeLog.shared.setKey("", name: voice.apiKeyIdentifier)
        await controller.selectVoiceOutput(DesktopSpeechVoice.deepgram(DeepgramSpeechCatalog.voices[0]))
        await controller.playGeneratedVoice(result.id.uuidString)
        await finish()
        let destination = directory.deletingLastPathComponent().appendingPathComponent("synthetic-xai-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: destination) }
        await controller.exportGeneratedVoice(result.id.uuidString, path: destination.path)
        let task = await controller.readAloudState.exportTask
        await task?.value
        XCTAssertEqual(try Data(contentsOf: destination), wav)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    private func finish() async {
        let task = await controller.voiceGenerationTask
        await task?.value
    }
}
