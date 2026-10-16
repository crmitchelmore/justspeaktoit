import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
import SpeakTestSupport
@testable import SpeakDesktopHost
import XCTest

final class DesktopHostVoiceQualityTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var session: URLSession!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("voice-quality-\(UUID())")
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        session = StubURLProtocol.makeSession()
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        await controller.close()
        session.invalidateAndCancel()
        StubURLProtocol.reset()
        FakeLog.shared.reset()
        try FileManager.default.removeItem(at: directory)
    }

    func testLegacyModel_DerivesEditorQualityWithoutChangingTheExplicitRouteOnUnrelatedSave() async throws {
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Quality presentation read a credential") }
        let original = DesktopSpeechVoice.openai(.mini, OpenAITTSCatalog.voices[0])
        var saved = DesktopVoiceOutputSettings(voice: original)
        saved.modelID = OpenAITTSModel.mini.rawValue
        XCTAssertNil(saved.quality)
        await controller.saveVoiceOutput(saved)
        let before = try await controller.currentVoiceSelection()
        XCTAssertEqual(before.voice, original)
        XCTAssertNil(before.options.quality)
        let editor = try await controller.voiceConfigurationEditorSnapshot()
        XCTAssertEqual(editor.preferences.values["ttsQuality"], AnyCodable(.string("standard")))
        XCTAssertTrue(editor.qualityTitle.contains("OpenAI model"))
        XCTAssertTrue(editor.qualityEnabled)
        try await controller.saveConfiguration(editor.preferences.entries)
        let after = await controller.voiceOutputSettings()
        XCTAssertEqual(after.modelID, saved.modelID)
        XCTAssertEqual(after.voiceID, saved.voiceID)
        XCTAssertEqual(after.quality, "standard")
        XCTAssertEqual(try after.synthesisSelection().voice, original)
        let packet = try JSONDecoder().decode(VoiceSynthesisOptions.self,
            from: Data(#"{"speed":0.25,"pitch":0,"useSSML":false}"#.utf8))
        let epoch = await controller.voiceCredentialEpoch
        let accepted = await controller.saveVoiceSynthesisOptions(packet)
        XCTAssertTrue(accepted)
        let retained = await controller.voiceOutputSettings()
        let retainedEpoch = await controller.voiceCredentialEpoch
        XCTAssertEqual(retained.quality, "standard")
        XCTAssertEqual(retained.speed, 0.25)
        XCTAssertEqual(retainedEpoch, epoch)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testQualityEditorAndExplicitPicker_ProjectOneEffectiveTupleAndVoiceScopedFavorites() async throws {
        let preset = OpenAITTSCatalog.voices[0]
        let original = DesktopSpeechVoice.openai(.standard, preset)
        var saved = DesktopVoiceOutputSettings(voice: original)
        saved.favoriteVoices = [original.favoriteIdentifier, "future/Voice", original.favoriteIdentifier]
        saved.language = "en_GB"
        saved.sonioxRegion = "future-region"
        await controller.saveVoiceOutput(saved)
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Quality editing read a credential") }
        let epoch = await controller.voiceCredentialEpoch
        var entries = try await controller.voiceConfigurationEditorSnapshot().preferences.entries
        entries[try qualityIndex()] = "highest"
        try await controller.saveConfiguration(entries)
        let changed = await controller.voiceOutputSettings()
        let changedEpoch = await controller.voiceCredentialEpoch
        let effective = DesktopSpeechVoice.openai(.highDefinition, preset)
        XCTAssertNotEqual(changedEpoch, epoch)
        XCTAssertEqual(try VoiceOutputCredentialSlot(voice: effective), try VoiceOutputCredentialSlot(voice: original))
        XCTAssertEqual(changed.modelID, original.modelID)
        XCTAssertEqual(changed.voiceID, original.id)
        XCTAssertEqual(changed.quality, "highest")
        XCTAssertEqual(changed.language, saved.language)
        XCTAssertEqual(changed.sonioxRegion, saved.sonioxRegion)
        XCTAssertEqual(changed.favoriteVoices, saved.favoriteVoices)
        XCTAssertEqual(try changed.synthesisSelection().voice, effective)
        let shown = changed.favoritePicker(accountInventory: nil)
        XCTAssertEqual(shown.identifiers[shown.selected], effective.pickerIdentifier)
        XCTAssertEqual(shown.labels[shown.selected], effective.label)
        XCTAssertTrue(changed.controlsPresentation.label.contains("TTS-1 HD"))
        XCTAssertEqual(changed.controlsPresentation.minimumSpeed, 0.25)
        XCTAssertEqual(changed.controlsPresentation.maximumSpeed, 4)
        await controller.handleVoicePicker(
            voiceID: DesktopSpeechVoice.openai(.mini, preset).pickerIdentifier, action: 0)
        let explicit = await controller.voiceOutputSettings()
        XCTAssertEqual(explicit.modelID, OpenAITTSModel.mini.desktopModelIdentifier)
        XCTAssertEqual(explicit.quality, "standard")
        XCTAssertEqual(explicit.favoriteVoices, saved.favoriteVoices)
        XCTAssertEqual(try explicit.synthesisSelection().voice, .openai(.mini, preset))
    }

    func testUnknownQuality_TransfersRestartsAndProjectsAnUnsupportedRowWithoutCredentialAccess() async throws {
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Unknown quality accessed a credential") }
        let voice = DesktopSpeechVoice.openai(.mini, OpenAITTSCatalog.voices[0])
        await controller.saveVoiceOutput(.init(voice: voice))
        try await importValues(["ttsQuality": AnyCodable(.string("future-quality"))])
        let saved = await controller.voiceOutputSettings()
        XCTAssertEqual(saved.quality, "future-quality")
        XCTAssertEqual(saved.modelID, voice.modelID)
        let raw = try await controller.configuration()
        XCTAssertNil(raw.values["ttsQuality"])
        let editor = try await controller.voiceConfigurationEditorSnapshot()
        let field = DesktopConfiguration.fields[try qualityIndex()]
        XCTAssertEqual(editor.preferences.entries[try qualityIndex()], "future-quality")
        XCTAssertTrue(editor.preferences.serializedChoices(for: field)?.contains(
            "future-quality\tUnsupported stored quality") == true)
        XCTAssertTrue(editor.qualityTitle.contains("unavailable"))
        XCTAssertEqual(saved.controlsPresentation.capabilities, 0)
        XCTAssertThrowsError(try saved.synthesisSelection()) {
            XCTAssertEqual($0 as? VoiceSynthesisConfigurationError, .unsupportedQuality)
        }
        let destination = directory.appendingPathComponent("quality-export.json")
        try await controller.exportConfiguration(path: destination.path)
        let document = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: destination))
        XCTAssertEqual(document.preferences.values["ttsQuality"], AnyCodable(.string("future-quality")))
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic unavailable quality.")
        await controller.generateVoiceSource(
            source,
            options: .init(autoPlay: false, saveToRecordings: false)
        ) { _, _, _ in
            XCTFail("Unsupported quality reached synthesis")
            return Data()
        }
        let result = await controller.generatedVoice
        XCTAssertNil(result)
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        let restored = await controller.voiceOutputSettings()
        XCTAssertEqual(restored, saved)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testMalformedQualityImport_IsAtomicAndCannotEraseTheCurrentSoleModel() async throws {
        await controller.selectVoiceOutput(.openai(.highDefinition, OpenAITTSCatalog.voices[0]))
        let file = directory.appendingPathComponent("settings.json")
        let original = try Data(contentsOf: file)
        for value in [AnyCodable(.bool(true)), AnyCodable(.int(1)), AnyCodable(.null),
                      AnyCodable(.string("bad\nquality")), AnyCodable(.string(String(repeating: "x", count: 257)))] {
            do {
                try await importValues(["ttsQuality": value, "ttsAutoPlay": AnyCodable(.bool(false))])
                XCTFail("Malformed quality was imported")
            } catch { XCTAssertTrue(error is DesktopConfigurationError) }
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
        let saved = await controller.voiceOutputSettings()
        XCTAssertEqual(saved.quality, "highest")
    }

}

extension DesktopHostVoiceQualityTests {
    func testIncompatibleOpenAIVoice_StaysUnavailableUntilAnExplicitCompatibleQualityOrTupleIsChosen() async throws {
        let preset = try XCTUnwrap(OpenAITTSCatalog.voices.first { !$0.supportsLegacyModels })
        await controller.selectVoiceOutput(.openai(.mini, preset))
        let accepted = await controller.saveVoiceSynthesisOptions(try VoiceSynthesisOptions(quality: .highest))
        XCTAssertTrue(accepted)
        let saved = await controller.voiceOutputSettings()
        XCTAssertEqual(saved.voiceID, preset.providerVoiceID)
        XCTAssertEqual(saved.modelID, OpenAITTSModel.mini.desktopModelIdentifier)
        XCTAssertEqual(saved.quality, "highest")
        XCTAssertThrowsError(try saved.synthesisSelection())
        let shown = saved.favoritePicker(accountInventory: nil)
        XCTAssertEqual(shown.identifiers[shown.selected], "")
        let defaults = try VoiceSynthesisOptions()
        _ = await controller.saveVoiceSynthesisOptions(defaults)
        let unchanged = await controller.voiceOutputSettings()
        XCTAssertEqual(unchanged.quality, "highest")
        await controller.selectVoiceOutput(.openai(.mini, preset))
        let repaired = await controller.voiceOutputSettings()
        XCTAssertEqual(repaired.quality, "standard")
        XCTAssertEqual(try repaired.synthesisSelection().voice, .openai(.mini, preset))
    }

    func testGeneration_CapturesQualityModelAndFullSpeedDespiteLaterPreferenceAndProviderChanges() async throws {
        let preset = OpenAITTSCatalog.voices[0]
        await controller.selectVoiceOutput(.openai(.standard, preset))
        _ = await controller.saveVoiceSynthesisOptions(try VoiceSynthesisOptions(speed: 4, quality: .highest))
        FakeLog.shared.setKey("synthetic-key", name: OpenAITTSCatalog.credentialIdentifier)
        FakeLog.shared.installKeyReadHook { name in XCTAssertEqual(name, OpenAITTSCatalog.credentialIdentifier) }
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data(repeating: 1, count: 480), sampleRate: 24_000))
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                statusCode: 200, httpVersion: nil, headerFields: nil)), wav)
        }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic captured quality.")
        let admitted = expectation(description: "Captured quality and model")
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { continuation.finish() }
        let transport = try XCTUnwrap(session)
        await controller.generateVoiceSource(
            source,
            options: .init(autoPlay: false, saveToRecordings: false)
        ) { snapshot, selection, credential in
            XCTAssertEqual(selection.voice, .openai(.highDefinition, preset))
            XCTAssertEqual(selection.options.quality, .highest)
            XCTAssertEqual(selection.options.speed, 4)
            admitted.fulfill()
            for await _ in stream { break }
            return try await DesktopSpeechSynthesis(session: transport).synthesize(
                snapshot, voice: selection.voice, options: selection.options, credential: credential)
        }
        await fulfillment(of: [admitted], timeout: 3)
        _ = await controller.saveVoiceSynthesisOptions(try VoiceSynthesisOptions(quality: .standard))
        await controller.selectVoiceOutput(.deepgram(DeepgramSpeechCatalog.voices[0]))
        continuation.yield(())
        continuation.finish()
        await controller.voiceGenerationTask?.value
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, OpenAITTSModel.highDefinition.rawValue)
        XCTAssertEqual((body["speed"] as? NSNumber)?.doubleValue, 4)
        let generated = await controller.generatedVoice
        XCTAssertEqual(generated?.voice, .openai(.highDefinition, preset))
        XCTAssertEqual(generated?.options.quality, .highest)
        XCTAssertEqual(generated?.audio.wav, wav)
    }

    func testHighRateDeepgramRead_UsesGenericNativePlaybackNotTheFixed24kSegmentEngine() async throws {
        await controller.selectVoiceOutput(.deepgram(DeepgramSpeechCatalog.voices[0]))
        _ = await controller.saveVoiceSynthesisOptions(try VoiceSynthesisOptions(quality: .highest))
        FakeLog.shared.setKey("synthetic-key", name: VoiceOutputProvider.deepgram.apiKeyIdentifier)
        FakeLog.shared.installKeyReadHook { name in
            XCTAssertEqual(name, VoiceOutputProvider.deepgram.apiKeyIdentifier)
        }
        let folder = try XCTUnwrap(directory).appendingPathComponent("VoiceGeneratedPlayback")
        let expected = try XCTUnwrap(PCMWaveWriter.wavData(pcm: Data([1, 0, 2, 0]), sampleRate: 48_000))
        FakeSpeech.shared.setPlaybackHook {
            let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, 1)
            let file = try XCTUnwrap(files.first)
            let data = try Data(contentsOf: file)
            XCTAssertEqual(data, expected)
            let audio = try VoiceGeneratedAudio(validating: data, sampleRate: 48_000)
            XCTAssertEqual(audio.sampleRate, 48_000)
            XCTAssertEqual(audio.duration, 2.0 / 48_000, accuracy: 0.000001)
        }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic 48 kHz read.")
        await controller.readVoiceSource(source)
        await controller.readAloudState.task?.value
        XCTAssertTrue(FakeSpeech.shared.spoken.isEmpty)
        XCTAssertEqual(FakeSpeech.shared.events, ["begin", "play", "end"])
        XCTAssertEqual(FakeLog.shared.allStatuses.last, "Finished reading aloud.")
        let files = try FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent("VoiceGeneratedPlayback").path)
        XCTAssertTrue(files.isEmpty)
        let selection = try await controller.currentVoiceSelection()
        XCTAssertEqual(selection.sampleRate, 48_000)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testFixedFormatProviders_DisableUnusedQualityButAllowExplicitRepairOfAnUnknownStoredChoice() async throws {
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Quality availability read a credential") }
        for voice in DesktopSpeechVoice.voices where !voice.supportsQualityControls {
            var saved = DesktopVoiceOutputSettings(voice: voice)
            saved.quality = "highest"
            await controller.saveVoiceOutput(saved)
            let editor = try await controller.voiceConfigurationEditorSnapshot()
            XCTAssertFalse(editor.qualityEnabled)
            XCTAssertTrue(editor.qualityTitle.contains("fixed format"))
            XCTAssertEqual(editor.preferences.values["ttsQuality"], AnyCodable(.string("highest")))
            XCTAssertEqual(try saved.synthesisSelection().voice, voice)
            XCTAssertEqual(try saved.synthesisSelection().sampleRate, voice.sampleRate)
        }
        var unknown = DesktopVoiceOutputSettings(voice: .gemini(GeminiTTSCatalog.defaultVoice))
        unknown.quality = "future-quality"
        await controller.saveVoiceOutput(unknown)
        let editor = try await controller.voiceConfigurationEditorSnapshot()
        XCTAssertTrue(editor.qualityEnabled)
        XCTAssertTrue(editor.qualityTitle.contains("unavailable"))
        var entries = editor.preferences.entries
        entries[try qualityIndex()] = "high"
        try await controller.saveConfiguration(entries)
        let repaired = await controller.voiceOutputSettings()
        XCTAssertEqual(repaired.quality, "high")
        XCTAssertEqual(try repaired.synthesisSelection().sampleRate, 24_000)
    }

    private func qualityIndex() throws -> Int {
        try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == ApplicationPreferenceKey.ttsQuality.rawValue })
    }

    private func importValues(_ values: [String: AnyCodable]) async throws {
        let document = try DesktopConfigurationDocument(preferences: DesktopConfiguration(values: values))
        let path = directory.appendingPathComponent("quality-import.json")
        try JSONEncoder().encode(document).write(to: path)
        try await controller.importConfiguration(path: path.path)
    }
}
