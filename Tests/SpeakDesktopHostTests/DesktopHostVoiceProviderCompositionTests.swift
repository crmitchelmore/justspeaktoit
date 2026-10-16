import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
import SpeakTestSupport
@testable import SpeakDesktopHost
import XCTest

final class DesktopHostVoiceProviderCompositionTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var session: URLSession!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-composition-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        session = StubURLProtocol.makeSession()
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        try FileManager.default.removeItem(at: directory)
    }

    func testNativeRows_SelectEveryOpenAIModelAndKeepFavoriteEditsVoiceScoped() async throws {
        let preset = OpenAITTSCatalog.voices[0]
        let tuples = OpenAITTSCatalog.models.map { DesktopSpeechVoice.openai($0, preset) }
        for voice in tuples {
            let initial = await controller.voiceOutputSettings()
            let picker = initial.favoritePicker(accountInventory: nil)
            let row = try XCTUnwrap(picker.identifiers.firstIndex(of: voice.pickerIdentifier))
            XCTAssertEqual(picker.labels[row], voice.label)
            await controller.handleVoicePicker(voiceID: picker.identifiers[row], action: 0)
            let selected = await controller.voiceOutputSettings()
            XCTAssertEqual(try selected.synthesisSelection().voice, voice)
            XCTAssertEqual(selected.favoritePicker(accountInventory: nil).identifiers[
                selected.favoritePicker(accountInventory: nil).selected], voice.pickerIdentifier)
        }
        let epoch = await controller.voiceCredentialEpoch
        await controller.handleVoicePicker(voiceID: tuples[1].pickerIdentifier, action: 1)
        let saved = await controller.voiceOutputSettings()
        XCTAssertEqual(saved.modelID, tuples[2].modelID)
        XCTAssertEqual(saved.favoriteVoices, [preset.providerVoiceID])
        let unchangedEpoch = await controller.voiceCredentialEpoch
        XCTAssertEqual(unchangedEpoch, epoch)
        let picker = saved.favoritePicker(accountInventory: nil)
        for (rank, voice) in tuples.enumerated() {
            let index = try XCTUnwrap(picker.identifiers.firstIndex(of: voice.pickerIdentifier))
            XCTAssertEqual(picker.favoriteRanks[index], Int32(rank))
        }
        let ranks = picker.favoriteRanks.filter { $0 >= 0 }
        XCTAssertEqual(Set(ranks).count, ranks.count)
        await controller.handleVoicePicker(voiceID: tuples[0].pickerIdentifier, action: 2)
        let removed = await controller.voiceOutputSettings()
        XCTAssertEqual(removed.favoriteVoices, [])
        XCTAssertEqual(removed.modelID, tuples[2].modelID)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testUnknownSettings_RoundTripWithoutCoercionAndRemainVisibleAfterProviderChoice() async throws {
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Picker repair read a credential") }
        var unknown = DesktopVoiceOutputSettings(modelID: "future/model", voiceID: "future/Voice")
        unknown.autoPlay = false
        unknown.saveToRecordings = true
        unknown.speed = 1.5
        unknown.pitch = 2
        unknown.useSSML = true
        unknown.trackUsage = false
        unknown.favoriteVoices = ["future/Voice", "openai/alloy", "future/Voice"]
        unknown.sonioxRegion = "future-region"
        unknown.language = "future_LANGUAGE"
        await controller.saveVoiceOutput(unknown)
        let stored = await controller.voiceOutputSettings()
        XCTAssertEqual(stored, unknown)
        XCTAssertThrowsError(try stored.synthesisSelection())
        XCTAssertEqual(stored.controlsPresentation.capabilities, 0)
        let unavailable = stored.favoritePicker(accountInventory: nil)
        XCTAssertEqual(unavailable.identifiers[unavailable.selected], "")
        XCTAssertEqual(try JSONDecoder().decode(DesktopVoiceOutputSettings.self,
            from: JSONEncoder().encode(stored)), unknown)
        let voice = DesktopSpeechVoice.openai(.highDefinition, OpenAITTSCatalog.voices[0])
        await controller.handleVoicePicker(voiceID: voice.pickerIdentifier, action: 0)
        var expected = unknown
        expected.modelID = voice.modelID
        expected.voiceID = voice.id
        expected.quality = "highest"
        let chosen = await controller.voiceOutputSettings()
        XCTAssertEqual(chosen, expected)
        XCTAssertEqual(chosen.quality, VoiceSynthesisQuality.highest.rawValue)
        XCTAssertEqual(try VoiceOutputCredentialSlot(voice: voice).identifier, "openai.tts.apiKey")
        XCTAssertEqual(chosen.controlsPresentation.capabilities, 1)
        XCTAssertThrowsError(try chosen.synthesisSelection()) {
            XCTAssertEqual($0 as? VoiceSynthesisConfigurationError, .unsupportedControls)
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testGeneration_CapturesOldModelSpeedTextAndDedicatedKeyDespiteLaterSettings() async throws {
        let voice = DesktopSpeechVoice.openai(.highDefinition, OpenAITTSCatalog.voices[0])
        await controller.selectVoiceOutput(voice)
        let saved = await controller.saveVoiceSynthesisOptions(try VoiceSynthesisOptions(speed: 1.5))
        XCTAssertTrue(saved)
        FakeLog.shared.setKey("synthetic-tts-only", name: OpenAITTSCatalog.credentialIdentifier)
        FakeLog.shared.setKey("synthetic-transcription-not-tts", name: "openai.apiKey")
        FakeLog.shared.setKey("synthetic-other-provider", name: GeminiTTSCatalog.credentialIdentifier)
        let pcm = Data(repeating: 1, count: 480)
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 24_000))
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                statusCode: 200, httpVersion: nil, headerFields: nil)), wav)
        }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic captured text.")
        let admitted = expectation(description: "Immutable selection admitted")
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { continuation.finish() }
        let transport = try XCTUnwrap(session)
        await controller.generateVoiceSource(source, options: .init(autoPlay: false, saveToRecordings: false)) {
            snapshot, selection, credential in
            admitted.fulfill()
            for await _ in stream { break }
            return try await DesktopSpeechSynthesis(session: transport).synthesize(
                snapshot, voice: selection.voice, options: selection.options, credential: credential)
        }
        await fulfillment(of: [admitted], timeout: 3)
        await controller.selectVoiceOutput(.gemini(GeminiTTSCatalog.defaultVoice))
        _ = await controller.saveVoiceSynthesisOptions(try VoiceSynthesisOptions())
        continuation.yield(())
        continuation.finish()
        await controller.voiceGenerationTask?.value
        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        XCTAssertEqual(request.url, OpenAITTSAPI.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-tts-only")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request))
            as? [String: Any])
        XCTAssertEqual(body["model"] as? String, OpenAITTSModel.highDefinition.rawValue)
        XCTAssertEqual(body["speed"] as? Double, 1.5)
        XCTAssertEqual(body["input"] as? String, source.text)
        let result = await controller.generatedVoice
        XCTAssertEqual(result?.voice, voice)
        XCTAssertEqual(result?.options.speed, 1.5)
        XCTAssertEqual(result?.source, source)
        XCTAssertEqual(result?.audio.wav, wav)
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
    }
}
