import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class DesktopGeminiConfigurationTests: DeepgramSpeechStubTestCase {
    func testCanonicalModels_ProjectEveryTupleAndRetainDefaultAndVoiceScopedFavorites() throws {
        let expected = GeminiTTSCatalog.models.flatMap { model in
            GeminiTTSCatalog.voices.map { DesktopSpeechVoice.gemini($0, model: model) }
        }
        let projected = DesktopSpeechVoice.voices.filter { if case .gemini = $0 { return true }; return false }
        XCTAssertEqual(projected, expected)
        XCTAssertEqual(projected.count, GeminiTTSCatalog.models.count * GeminiTTSCatalog.voices.count)
        XCTAssertEqual(Set(projected.map(\.pickerIdentifier)).count, projected.count)
        let preset = GeminiTTSCatalog.defaultVoice
        XCTAssertEqual(DesktopSpeechVoice.gemini(preset), .gemini(preset, model: GeminiTTSCatalog.defaultModel))
        XCTAssertEqual(GeminiTTSCatalog.desktopModelIdentifier, GeminiTTSCatalog.defaultModel.desktopModelIdentifier)
        for voice in projected {
            XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: voice.modelID, voiceID: voice.id), voice)
            XCTAssertEqual(voice.favoriteIdentifier, voice.id)
            XCTAssertEqual(voice.pickerIdentifier, voice.modelID + "|" + voice.id)
            XCTAssertEqual(try VoiceOutputCredentialSlot(voice: voice).identifier, GeminiTTSCatalog.credentialIdentifier)
            guard case .gemini(_, let model) = voice else { return XCTFail("Wrong projected provider") }
            XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: model.rawValue, voiceID: voice.id), voice)
            XCTAssertTrue(voice.label.contains(model.displayName))
        }
        let tuples = GeminiTTSCatalog.models.map { DesktopSpeechVoice.gemini(preset, model: $0) }
        let picker = DesktopVoicePicker(voices: tuples + tuples, favoriteIDs: [
            "future/Voice", preset.providerVoiceID, preset.providerVoiceID
        ])
        XCTAssertEqual(picker.voices, tuples)
        XCTAssertEqual(picker.favorites, tuples.map { _ in true })
        XCTAssertEqual(picker.favoriteIndices, [0])
        for model in [nil, GeminiTTSCatalog.providerIdentifier] {
            XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: model, voiceID: preset.providerVoiceID),
                           .gemini(preset))
        }
    }

    func testEachModel_UsesCapturedModelRegionalLanguageCredentialAndCanonicalUsageRates() async throws {
        let response = try audioResponse()
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), response) }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic Gemini configuration.")
        for model in GeminiTTSCatalog.models {
            let voice = DesktopSpeechVoice.gemini(GeminiTTSCatalog.defaultVoice, model: model)
            let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .typedText, historyRecordID: nil)
            let probe = CredentialProbe("synthetic-key")
            let bytes = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                try await DesktopSpeechSynthesis(session: session).synthesize(
                    source, voice: voice, options: VoiceSynthesisOptions(), accountInventory: nil,
                    language: "en_GB", credential: { try await probe.supply() })
            }
            XCTAssertEqual(probe.count, 1)
            XCTAssertEqual(bytes, DeepgramSpeechFixture.canonicalWAV(pcm: pcm))
            let sent = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
            let canonical = try GeminiTTSAPI.synthesisRequest(input: source.text, apiKey: "synthetic-key",
                request: GeminiTTSRequest(model: model, voiceID: voice.id, languageIdentifier: "en_GB"))
            XCTAssertEqual(sent.url, canonical.url)
            XCTAssertEqual(sent.value(forHTTPHeaderField: GeminiTTSAPI.apiKeyHeader),
                           canonical.value(forHTTPHeaderField: GeminiTTSAPI.apiKeyHeader))
            let json = try body(sent)
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: json, options: .sortedKeys),
                           try JSONSerialization.data(withJSONObject: body(canonical), options: .sortedKeys))
            XCTAssertEqual(json["model"] as? String, model.rawValue)
            let generation = try XCTUnwrap(json["generation_config"] as? [String: Any])
            let speech = try XCTUnwrap((generation["speech_config"] as? [[String: Any]])?.first)
            XCTAssertEqual(speech["language"] as? String, "en-GB")
            let record = try XCTUnwrap(capture.records.first)
            XCTAssertEqual(record.modelID, model.desktopModelIdentifier)
            XCTAssertEqual(record.reportedInputTokens, 7)
            XCTAssertEqual(record.estimatedInputCostUSD, Decimal(7) * model.costPerInputToken)
            let seconds = Double(pcm.count) / 48_000
            XCTAssertEqual(record.estimatedAudioCostUSD, Decimal(seconds) * model.costPerSecondOfSpeech)
            XCTAssertEqual(record.outcome, .completed)
        }
    }

    func testEveryCanonicalLanguage_IsRetainedWhileTheSharedRequestAloneResolvesItsWireTag() throws {
        let voice = DesktopSpeechVoice.gemini(GeminiTTSCatalog.defaultVoice)
        for option in VoiceOutputLanguageCatalog.options {
            let captured = try DesktopSpeechSelection(
                voice: voice, options: VoiceSynthesisOptions(), accountInventory: nil, language: option.id)
            XCTAssertEqual(captured.language, option.id)
            let request = GeminiTTSRequest(voiceID: voice.id, languageIdentifier: captured.language)
            let expected = GeminiTTSRequest(voiceID: voice.id, languageIdentifier: option.id)
            XCTAssertEqual(request, expected)
        }
        for identifier in ["en_GB", "en-GB", "EN_gb"] {
            let captured = try DesktopSpeechSelection(
                voice: voice, options: VoiceSynthesisOptions(), accountInventory: nil, language: identifier)
            XCTAssertEqual(captured.language, identifier)
            XCTAssertEqual(GeminiTTSRequest(voiceID: voice.id, languageIdentifier: captured.language).languageTag, "en-GB")
        }
        for identifier in [nil, "", "automatic", "en"] {
            XCTAssertNil(GeminiTTSRequest(voiceID: voice.id, languageIdentifier: identifier).languageTag)
        }
    }

    func testLanguageMetadata_IsOneExistingTextFieldWithHonestProviderAwareLabels() throws {
        let fields = DesktopConfiguration.fields.filter { $0.key == VoiceOutputLanguagePreference.key }
        let field = try XCTUnwrap(fields.first)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(SonioxVoicePreference.languageKey, VoiceOutputLanguagePreference.key)
        XCTAssertEqual(field.title, VoiceOutputLanguagePreference.field.title)
        XCTAssertTrue(field.title.contains("Gemini / Soniox"))
        guard case .text = field.kind else { return XCTFail("Language became a lossy native choice") }
        XCTAssertEqual(field.defaultValue, AnyCodable(.string(VoiceOutputLanguageCatalog.automaticIdentifier)))
        XCTAssertEqual(DesktopConfiguration.fields.last?.key, VoiceOutputLanguagePreference.key)
        XCTAssertEqual(DesktopConfiguration.fields.dropLast().last?.key, SonioxVoicePreference.regionKey)
        XCTAssertTrue(VoiceOutputLanguagePreference.title(for: .gemini(GeminiTTSCatalog.defaultVoice))
            .hasPrefix("Gemini"))
        let soniox = try DesktopSpeechVoice.resolved(
            modelID: "soniox", voiceID: SonioxTTSCatalog.voices[0].providerVoiceID)
        XCTAssertTrue(VoiceOutputLanguagePreference.title(for: soniox).hasPrefix("Soniox"))
        XCTAssertTrue(VoiceOutputLanguagePreference.title(for: .deepgram(DeepgramSpeechCatalog.voices[0]))
            .contains("not used"))
        XCTAssertTrue(VoiceOutputLanguagePreference.title(for: nil).contains("unavailable"))
    }

    func testUnknownModelsLanguagesAndUnsupportedOptions_RefuseBeforeCredentialOrTransport() async throws {
        let voice = DesktopSpeechVoice.gemini(GeminiTTSCatalog.defaultVoice)
        for identifier in ["gemini-2.5-flash-preview-tts", "google/future-tts", "gemini-3.5-transcribe"] {
            XCTAssertNil(GeminiTTSCatalog.model(forID: identifier))
            XCTAssertThrowsError(try DesktopSpeechVoice.resolved(modelID: identifier, voiceID: voice.id))
        }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic invalid choice.")
        let probe = CredentialProbe()
        for model in GeminiTTSCatalog.models {
            let tuple = DesktopSpeechVoice.gemini(GeminiTTSCatalog.defaultVoice, model: model)
            for language in ["future_LANGUAGE", "en_UNKNOWN"] {
                do {
                    _ = try await DesktopSpeechSynthesis(session: session).synthesize(
                        source, voice: tuple, options: VoiceSynthesisOptions(), accountInventory: nil,
                        language: language, credential: { try await probe.supply() })
                    XCTFail("Unknown language was accepted")
                } catch { XCTAssertEqual(error as? DesktopGeminiSpeechError, .unsupportedLanguage) }
            }
            do {
                _ = try await DesktopSpeechSynthesis(session: session).synthesize(
                    source, voice: tuple, options: VoiceSynthesisOptions(speed: 1.25),
                    accountInventory: nil, language: "en_GB", credential: { try await probe.supply() })
                XCTFail("Unsupported speed was ignored")
            } catch { XCTAssertEqual(error as? VoiceSynthesisConfigurationError, .unsupportedControls) }
        }
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testPrecancelledCapturedModelAndLanguage_NeverReadTheKey() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic cancelled choice.")
        let probe = CredentialProbe()
        let model = try XCTUnwrap(GeminiTTSCatalog.models.last)
        let voice = DesktopSpeechVoice.gemini(GeminiTTSCatalog.defaultVoice, model: model)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DesktopSpeechSynthesis(session: session).synthesize(
                source, voice: voice, options: VoiceSynthesisOptions(), accountInventory: nil,
                language: "en_GB", credential: { try await probe.supply() })
        }
        do { _ = try await task.value; XCTFail("Cancelled selection executed") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    private func audioResponse() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "steps": [["content": [[
                "type": "audio", "data": pcm.base64EncodedString(), "mime_type": "audio/l16",
                "sample_rate": 24_000, "channels": 1
            ]]]], "usage": ["input_tokens": 7]
        ])
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any])
    }
}
