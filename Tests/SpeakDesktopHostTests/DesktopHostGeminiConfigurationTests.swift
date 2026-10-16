import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
import SpeakDesktop
import SpeakTestSupport
@testable import SpeakDesktopHost
import XCTest

final class DesktopHostGeminiConfigurationTests: XCTestCase {
    private var directory: URL!
    private var controller: DesktopHostController<FakePlatform>!
    private var session: URLSession!

    override func setUp() async throws {
        FakeLog.shared.reset()
        FakeSpeech.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-configuration-\(UUID())")
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

    func testProviderAwareEditor_CapturesLabelsAndPreservedValuesWithoutCredentials() async throws {
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Language presentation read a credential") }
        var saved = DesktopVoiceOutputSettings(voice: .gemini(GeminiTTSCatalog.defaultVoice))
        saved.language = "en_GB"
        saved.sonioxRegion = "future-region"
        saved.favoriteVoices = ["future/Voice", saved.voiceID ?? "", "future/Voice"]
        saved.pitch = 2
        await controller.saveVoiceOutput(saved)
        let snapshot = try await controller.voiceConfigurationEditorSnapshot()
        XCTAssertTrue(snapshot.languageTitle.hasPrefix("Gemini"))
        XCTAssertEqual(snapshot.preferences.values[VoiceOutputLanguagePreference.key], AnyCodable(.string("en_GB")))
        let afterPresentation = await controller.voiceOutputSettings()
        XCTAssertEqual(afterPresentation, saved)
        let soniox = try DesktopSpeechVoice.resolved(
            modelID: "soniox", voiceID: SonioxTTSCatalog.voices[0].providerVoiceID)
        await controller.selectVoiceOutput(soniox)
        let sonioxSnapshot = try await controller.voiceConfigurationEditorSnapshot()
        XCTAssertTrue(sonioxSnapshot.languageTitle.hasPrefix("Soniox"))
        XCTAssertEqual(
            sonioxSnapshot.preferences.values[VoiceOutputLanguagePreference.key], AnyCodable(.string("en_GB")))
        await controller.selectVoiceOutput(.deepgram(DeepgramSpeechCatalog.voices[0]))
        let unused = try await controller.voiceConfigurationEditorSnapshot()
        XCTAssertTrue(unused.languageTitle.contains("not used"))
        XCTAssertEqual(unused.preferences.values[VoiceOutputLanguagePreference.key], AnyCodable(.string("en_GB")))
        await controller.saveVoiceOutput(.init(modelID: "google/future-tts", voiceID: "google/Future"))
        let unavailable = try await controller.voiceConfigurationEditorSnapshot()
        XCTAssertTrue(unavailable.languageTitle.contains("unavailable"))
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testNativeEditorAndTransfer_RetainRegionalLanguageInTheSoleModelAcrossRestart() async throws {
        let model = try XCTUnwrap(GeminiTTSCatalog.models.last)
        let voice = DesktopSpeechVoice.gemini(GeminiTTSCatalog.defaultVoice, model: model)
        var saved = DesktopVoiceOutputSettings(voice: voice)
        saved.language = "en_GB"
        saved.sonioxRegion = "future-region"
        saved.favoriteVoices = [voice.id, "future/Voice", voice.id]
        await controller.saveVoiceOutput(saved)
        FakeLog.shared.installKeyReadHook { _ in XCTFail("Language editing accessed a credential") }
        var entries = try await controller.voiceConfigurationEditorSnapshot().preferences.entries
        let language = try XCTUnwrap(DesktopConfiguration.fields.firstIndex {
            $0.key == VoiceOutputLanguagePreference.key
        })
        entries[language] = "pt_BR"
        try await controller.saveConfiguration(entries)
        saved.language = "pt_BR"
        let actual = await controller.voiceOutputSettings()
        XCTAssertEqual(actual.modelID, saved.modelID)
        XCTAssertEqual(actual.voiceID, saved.voiceID)
        XCTAssertEqual(actual.language, saved.language)
        XCTAssertEqual(actual.sonioxRegion, saved.sonioxRegion)
        XCTAssertEqual(actual.favoriteVoices, saved.favoriteVoices)
        let raw = try await controller.configuration()
        XCTAssertNil(raw.values[VoiceOutputLanguagePreference.key])
        let destination = directory.appendingPathComponent("language-export.json")
        try await controller.exportConfiguration(path: destination.path)
        let exported = try JSONDecoder().decode(DesktopConfigurationDocument.self, from: Data(contentsOf: destination))
        XCTAssertEqual(exported.preferences.values[VoiceOutputLanguagePreference.key], AnyCodable(.string("pt_BR")))
        let selection = try await controller.currentVoiceSelection()
        XCTAssertEqual(selection.language, "pt_BR")
        XCTAssertEqual(selection.voice, voice)
        await controller.close()
        controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        let restored = await controller.voiceOutputSettings()
        XCTAssertEqual(restored, actual)
        let restoredSnapshot = try await controller.voiceConfigurationEditorSnapshot()
        XCTAssertTrue(restoredSnapshot.languageTitle.hasPrefix("Gemini"))
        XCTAssertEqual(
            restoredSnapshot.preferences.values[VoiceOutputLanguagePreference.key], AnyCodable(.string("pt_BR")))
    }

    func testEveryCanonicalModel_NativePickerPersistsTupleWhileFavoritesRemainVoiceScoped() async throws {
        let preset = GeminiTTSCatalog.defaultVoice
        for model in GeminiTTSCatalog.models {
            let voice = DesktopSpeechVoice.gemini(preset, model: model)
            let initial = await controller.voiceOutputSettings()
            let shown = initial.favoritePicker(accountInventory: nil)
            let index = try XCTUnwrap(shown.identifiers.firstIndex(of: voice.pickerIdentifier))
            XCTAssertEqual(shown.labels[index], voice.label)
            await controller.handleVoicePicker(voiceID: shown.identifiers[index], action: 0)
            await controller.handleVoicePicker(voiceID: shown.identifiers[index], action: 1)
            let saved = await controller.voiceOutputSettings()
            XCTAssertEqual(saved.modelID, model.desktopModelIdentifier)
            XCTAssertEqual(saved.voiceID, preset.providerVoiceID)
            XCTAssertEqual(saved.favoriteVoices, [preset.providerVoiceID])
            let picker = saved.favoritePicker(accountInventory: nil)
            XCTAssertEqual(picker.identifiers[picker.selected], voice.pickerIdentifier)
            let ranks = picker.favoriteRanks.filter { $0 >= 0 }
            XCTAssertEqual(ranks.count, GeminiTTSCatalog.models.count)
            XCTAssertEqual(Set(ranks).count, ranks.count)
            XCTAssertEqual(try saved.synthesisSelection().voice, voice)
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    // existing owned test covering generation-before-later-editor-change ordering; no behavior change.
    // swiftlint:disable:next function_body_length
    func testGeneration_CapturesModelAndRegionalLanguageBeforeLaterEditorChanges() async throws {
        let voice = DesktopSpeechVoice.gemini(
            GeminiTTSCatalog.defaultVoice, model: try XCTUnwrap(GeminiTTSCatalog.models.last))
        var saved = DesktopVoiceOutputSettings(voice: voice)
        saved.language = "en_GB"
        await controller.saveVoiceOutput(saved)
        FakeLog.shared.setKey("synthetic-key", name: GeminiTTSCatalog.credentialIdentifier)
        let pcm = Data(repeating: 1, count: 480)
        let response = try JSONSerialization.data(withJSONObject: ["steps": [["content": [[
            "type": "audio", "data": pcm.base64EncodedString(), "mime_type": "audio/l16",
            "sample_rate": 24_000, "channels": 1
        ]]]]])
        StubURLProtocol.handler = { request in
            .respond(try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                statusCode: 200, httpVersion: nil, headerFields: nil)), response)
        }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic captured language.")
        let admitted = expectation(description: "Captured immutable Gemini selection")
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { continuation.finish() }
        let transport = try XCTUnwrap(session)
        await controller.generateVoiceSource(
            source,
            options: .init(autoPlay: false, saveToRecordings: false)
        ) { snapshot, selection, credential in
            XCTAssertEqual(selection.voice, voice)
            XCTAssertEqual(selection.language, "en_GB")
            admitted.fulfill()
            for await _ in stream { break }
            return try await DesktopSpeechSynthesis(session: transport).synthesize(
                snapshot, voice: selection.voice, options: selection.options,
                accountInventory: selection.accountInventory, language: selection.language, credential: credential)
        }
        await fulfillment(of: [admitted], timeout: 3)
        var entries = try await controller.voiceConfigurationEditorSnapshot().preferences.entries
        let language = try XCTUnwrap(DesktopConfiguration.fields.firstIndex {
            $0.key == VoiceOutputLanguagePreference.key
        })
        entries[language] = "fr_FR"
        try await controller.saveConfiguration(entries)
        await controller.selectVoiceOutput(.deepgram(DeepgramSpeechCatalog.voices[0]))
        continuation.yield(())
        continuation.finish()
        await controller.voiceGenerationTask?.value
        let sent = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: sent)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, GeminiTTSCatalog.model(forID: voice.modelID)?.rawValue)
        let generation = try XCTUnwrap(body["generation_config"] as? [String: Any])
        let speech = try XCTUnwrap((generation["speech_config"] as? [[String: Any]])?.first)
        XCTAssertEqual(speech["language"] as? String, "en-GB")
        let result = await controller.generatedVoice
        XCTAssertEqual(result?.voice, voice)
        XCTAssertEqual(result?.source, source)
        let usage = await controller.voiceUsageSummary()
        XCTAssertTrue(usage.contains("Gemini reported text-input tokens"))
        let current = await controller.voiceOutputSettings()
        XCTAssertEqual(current.language, "fr_FR")
        XCTAssertTrue(FakeSpeech.shared.events.isEmpty)
    }
}
