import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class DesktopVoiceProviderCompositionTests: DeepgramSpeechStubTestCase {
    func testProjection_PreservesExistingOrderAccountBoundaryAndEveryExecutableTuple() throws {
        var existing = DeepgramSpeechCatalog.voices.map(DesktopSpeechVoice.deepgram)
        existing.append(contentsOf: AzureNeuralVoiceCatalog.voices.map(DesktopSpeechVoice.azureNeural))
        existing.append(contentsOf: AzureMAIVoiceCatalog.voices.map(DesktopSpeechVoice.azureMAI))
        existing.append(contentsOf: XAITTSCatalog.voices.map(DesktopSpeechVoice.xai))
        existing.append(contentsOf: CartesiaTTSCatalog.voices.map(DesktopSpeechVoice.cartesia))
        existing.append(contentsOf: SonioxTTSCatalog.voices.map {
            .soniox(SonioxTTSCatalog.resolvedVoice(voiceID: $0.providerVoiceID, accountVoices: []))
        })
        let voices = DesktopSpeechVoice.voices
        XCTAssertEqual(Array(voices.prefix(existing.count)), existing)
        XCTAssertEqual(VoiceAccountProvider.all, [.xai, .mistral, .soniox])
        XCTAssertFalse(voices.contains { if case .mistral = $0 { return true }; return false })
        let picker = DesktopVoicePicker(voices: voices + voices, favoriteIDs: [])
        XCTAssertEqual(picker.voices, voices)
        XCTAssertEqual(Set(voices.map(\.pickerIdentifier)).count, voices.count)
        for voice in voices.dropFirst(existing.count) {
            XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: voice.modelID, voiceID: voice.id), voice)
            XCTAssertEqual(try VoiceOutputCredentialSlot(voice: voice).identifier, voice.apiKeyIdentifier)
        }
    }

    func testOpenAIPicker_DistinguishesModelsWithoutRewritingMacCompatibleFavorites() throws {
        let voice = OpenAITTSCatalog.voices[0]
        let tuples = OpenAITTSCatalog.models.map { DesktopSpeechVoice.openai($0, voice) }
        let picker = DesktopVoicePicker(voices: tuples + tuples, favoriteIDs: [
            "future/voice", voice.providerVoiceID, voice.providerVoiceID
        ])
        XCTAssertEqual(picker.voices, tuples)
        XCTAssertEqual(picker.favorites, [true, true, true])
        XCTAssertEqual(picker.favoriteIndices, [0])
        XCTAssertEqual(Set(tuples.map(\.pickerIdentifier)).count, 3)
        XCTAssertEqual(Set(tuples.map(\.favoriteIdentifier)), [voice.providerVoiceID])
        for tuple in tuples {
            XCTAssertEqual(tuple.apiKeyIdentifier, "openai.tts.apiKey")
            XCTAssertNotEqual(tuple.apiKeyIdentifier, "openai.apiKey")
            XCTAssertEqual(tuple.capabilities.nativeFlags, 1)
        }
    }

    func testAllFourRoutes_RejectUnsupportedControlsBeforeCredentialOrTransport() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic refusal.")
        let probe = CredentialProbe()
        for voice in routes {
            var invalid = [try VoiceSynthesisOptions(pitch: 1), try VoiceSynthesisOptions(useSSML: true)]
            if !voice.capabilities.speed { invalid.append(try VoiceSynthesisOptions(speed: 1.25)) }
            for options in invalid {
                do {
                    _ = try await DesktopSpeechSynthesis(session: session).synthesize(
                        source, voice: voice, options: options, credential: { try await probe.supply() })
                    XCTFail("Unsupported controls reached a new provider")
                } catch {
                    XCTAssertEqual(error as? VoiceSynthesisConfigurationError, .unsupportedControls)
                }
            }
        }
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testAllFourRoutes_PreCancelledWorkNeverReadsCredentialOrCreatesUsage() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic cancellation.")
        let probe = CredentialProbe()
        let transport = try XCTUnwrap(session)
        for voice in routes {
            let capture = VoiceSynthesisUsage.Capture(operation: .export, source: .clipboard, historyRecordID: nil)
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await VoiceSynthesisUsage.$capture.withValue(capture) {
                    try await DesktopSpeechSynthesis(session: transport).synthesize(
                        source, voice: voice, options: VoiceSynthesisOptions(),
                        credential: { try await probe.supply() })
                }
            }
            do {
                _ = try await task.value
                XCTFail("Cancelled work was admitted")
            } catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(capture.records.isEmpty)
        }
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testCompleteResponses_RejectStreamingPlaceholdersInsteadOfInventingLengths() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .textFile, text: "Synthetic complete result.")
        for voice in routes {
            StubURLProtocol.reset()
            var wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: voice.sampleRate))
            wav.replaceSubrange(4..<8, with: [0, 0, 0, 0])
            wav.replaceSubrange(40..<44, with: [0, 0, 0, 0])
            let body: Data
            if case .gemini = voice {
                body = try JSONSerialization.data(withJSONObject: ["steps": [["content": [[
                    "type": "audio", "data": wav.base64EncodedString(), "mime_type": "audio/wav",
                    "sample_rate": 24_000, "channels": 1
                ]]]]])
            } else { body = wav }
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), body) }
            let capture = VoiceSynthesisUsage.Capture(operation: .generate, source: .textFile, historyRecordID: nil)
            do {
                _ = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                    try await DesktopSpeechSynthesis(session: self.session).synthesize(
                        source, voice: voice, options: VoiceSynthesisOptions(), credential: { "synthetic-key" })
                }
                XCTFail("A completed route accepted an incomplete streaming header")
            } catch {
                XCTAssertEqual(error as? DesktopSpeechSynthesisError, .invalidAudio)
            }
            XCTAssertEqual(capture.records.map(\.outcome), [.failed])
            XCTAssertNil(capture.records.first?.audioDuration)
        }
    }

    func testLegacyUsage_RemainsDecodableAndNonGeminiDoesNotAcquireTokenPricing() throws {
        let capture = VoiceSynthesisUsage.Capture(operation: .read, source: .history, historyRecordID: UUID())
        let voice = DesktopSpeechVoice.azureMAI(AzureMAIVoiceCatalog.voices[0])
        let id = capture.begin(voice: voice, inputCharacters: 12, usesSSML: false)
        capture.finish(id, outcome: .completed, audioDuration: 1, reportedInputTokens: 42)
        let record = try XCTUnwrap(capture.records.first)
        XCTAssertNil(record.reportedInputTokens)
        XCTAssertNil(record.estimatedInputCostUSD)
        XCTAssertNil(record.estimatedAudioCostUSD)
        let json = try JSONEncoder().encode(capture.records)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("reportedInputTokens"))
        XCTAssertEqual(try JSONDecoder().decode([VoiceSynthesisUsage.Record].self, from: json), capture.records)
    }

    func testWhitespaceOnlySegments_RefuseTheWholeGroqAndGeminiOperationBeforeKeys() async throws {
        let probe = CredentialProbe()
        for (voice, limit) in [(DesktopSpeechVoice.groq(GroqTTSCatalog.defaultVoice), GroqTTSAPI.maxInputCharacters),
                               (.gemini(GeminiTTSCatalog.defaultVoice), GeminiTTSAPI.maxInputCharacters)] {
            let source = try VoiceOutputSourceSnapshot(source: .typedText,
                text: "a" + String(repeating: " ", count: limit * 2) + "b")
            do {
                _ = try await DesktopSpeechSynthesis(session: session).synthesize(
                    source, voice: voice, options: VoiceSynthesisOptions(), credential: { try await probe.supply() })
                XCTFail("Whitespace-only segments were admitted")
            } catch {
                if case .groq = voice {
                    XCTAssertEqual(error as? DesktopGroqSpeechError, .emptyText)
                } else { XCTAssertEqual(error as? DesktopGeminiSpeechError, .emptySegment) }
            }
        }
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testGeminiLanguage_UsesCapturedCanonicalRegionalTagAndRefusesUnknownBeforeKeys() async throws {
        let voice = DesktopSpeechVoice.gemini(GeminiTTSCatalog.defaultVoice)
        let source = try VoiceOutputSourceSnapshot(source: .clipboard, text: "Synthetic language preference.")
        let body = try JSONSerialization.data(withJSONObject: ["steps": [["content": [[
            "type": "audio", "data": pcm.base64EncodedString(), "mime_type": "audio/l16",
            "sample_rate": 24_000, "channels": 1
        ]]]]])
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), body) }
        _ = try await DesktopSpeechSynthesis(session: session).synthesize(
            source, voice: voice, options: VoiceSynthesisOptions(), accountInventory: nil,
            language: "en_GB", credential: { "synthetic-key" })
        let sent = try XCTUnwrap(StubURLProtocol.recordedRequests.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: sent)) as? [String: Any])
        let generation = try XCTUnwrap(json["generation_config"] as? [String: Any])
        let speech = try XCTUnwrap((generation["speech_config"] as? [[String: Any]])?.first)
        XCTAssertEqual(speech["language"] as? String, "en-GB")
        let probe = CredentialProbe()
        XCTAssertThrowsError(try DesktopSpeechSelection(
            voice: voice, options: VoiceSynthesisOptions(), accountInventory: nil, language: "future_LANGUAGE"))
        do {
            _ = try await DesktopSpeechSynthesis(session: session).synthesize(
                source, voice: voice, options: VoiceSynthesisOptions(), accountInventory: nil,
                language: "future_LANGUAGE", credential: { try await probe.supply() })
            XCTFail("Unknown language reached credential access")
        } catch { XCTAssertEqual(error as? DesktopGeminiSpeechError, .unsupportedLanguage) }
        XCTAssertEqual(probe.count, 0)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    private var routes: [DesktopSpeechVoice] {
        [.openai(.standard, OpenAITTSCatalog.voices[0]), .groq(GroqTTSCatalog.voices[0]),
         .gemini(GeminiTTSCatalog.defaultVoice), .speechmatics(SpeechmaticsTTSCatalog.defaultVoice)]
    }
}
