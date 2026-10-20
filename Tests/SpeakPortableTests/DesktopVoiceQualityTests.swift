import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class DesktopVoiceQualityTests: DeepgramSpeechStubTestCase {
    func testCanonicalQuality_MapsEveryCompatibleOpenAIModelWithoutReplacingTheVoice() throws {
        XCTAssertEqual(VoiceSynthesisQuality.allCases.map(\.rawValue), ["standard", "high", "highest"])
        XCTAssertEqual(VoiceSynthesisQuality.defaultValue, .high)
        for model in OpenAITTSCatalog.models {
            XCTAssertEqual(try OpenAITTSCatalog.model(forQualityIdentifier: model.quality.rawValue), model)
            for preset in OpenAITTSCatalog.voices {
                let initial = DesktopSpeechVoice.openai(.mini, preset)
                if preset.supports(model) {
                    let selection = try DesktopSpeechSelection(
                        voice: initial, options: VoiceSynthesisOptions(quality: model.quality))
                    XCTAssertEqual(selection.voice, .openai(model, preset))
                    XCTAssertEqual(selection.voice.id, initial.id)
                    XCTAssertEqual(selection.voice.favoriteIdentifier, initial.favoriteIdentifier)
                    XCTAssertEqual(selection.voice.apiKeyIdentifier, OpenAITTSCatalog.credentialIdentifier)
                    XCTAssertEqual(selection.sampleRate, 24_000)
                } else {
                    XCTAssertThrowsError(try initial.applyingQuality(model.quality)) {
                        XCTAssertEqual($0 as? VoiceSynthesisConfigurationError, .unsupportedVoice)
                    }
                }
            }
        }
    }

    func testLegacyAbsentQuality_RetainsEveryExplicitModelAndTheExistingPCMDefaults() throws {
        let old = Data(#"{"speed":1,"pitch":0,"useSSML":false}"#.utf8)
        let options = try JSONDecoder().decode(VoiceSynthesisOptions.self, from: old)
        XCTAssertNil(options.quality)
        for voice in DesktopSpeechVoice.voices {
            let selection = try DesktopSpeechSelection(voice: voice, options: options)
            XCTAssertEqual(selection.voice, voice)
            XCTAssertEqual(selection.sampleRate, voice.sampleRate)
        }
        XCTAssertNil(try VoiceSynthesisQuality.storedValue(nil))
        XCTAssertThrowsError(try VoiceSynthesisQuality.storedValue("future-quality")) {
            XCTAssertEqual($0 as? VoiceSynthesisConfigurationError, .unsupportedQuality)
        }
    }

    func testOpenAIFullSpeedAndQuality_UseExactCanonicalRequestModelCredentialAndUsage() async throws {
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 24_000))
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), wav) }
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic quality and speed.")
        let preset = OpenAITTSCatalog.voices[0]
        for model in OpenAITTSCatalog.models {
            for speed in [0.25, 4.0] {
                let capture = VoiceSynthesisUsage.Capture(
                    operation: .generate, source: .typedText, historyRecordID: nil)
                let probe = CredentialProbe("synthetic-key")
                let actual = try await VoiceSynthesisUsage.$capture.withValue(capture) {
                    try await DesktopSpeechSynthesis(session: session).synthesize(
                        source, voice: .openai(.standard, preset),
                        options: VoiceSynthesisOptions(speed: speed, quality: model.quality)
                    ) { try await probe.supply() }
                }
                XCTAssertEqual(actual, wav)
                XCTAssertEqual(probe.count, 1)
                let request = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
                let expected = try OpenAITTSAPI.synthesisRequest(text: source.text, apiKey: "synthetic-key",
                    request: OpenAITTSRequest(model: model, voiceID: preset.providerVoiceID, speed: speed))
                XCTAssertEqual(request.url, expected.url)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                               expected.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(try normalizedBody(request), try normalizedBody(expected))
                let body = try jsonBody(request)
                XCTAssertNil(body["instructions"])
                XCTAssertNil(body["style"])
                XCTAssertEqual(capture.records.first?.modelID, model.desktopModelIdentifier)
                XCTAssertEqual(capture.records.first?.outcome, .completed)
            }
        }
        XCTAssertEqual(VoiceSynthesisCapabilities.openai.speedRange, OpenAITTSAPI.speedRange)
        for speed in [0.24, 4.01, .nan, .infinity] {
            XCTAssertThrowsError(try VoiceSynthesisOptions(speed: speed))
        }
    }

    func testProviderSpeedBounds_RemainCanonicalAndRejectUnsupportedControlsBeforeCredentials() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic range refusal.")
        let voices = [
            DesktopSpeechVoice.azureNeural(AzureNeuralVoiceCatalog.voices[0]),
            .xai(XAITTSCatalog.voices[0]), .cartesia(CartesiaTTSCatalog.defaultVoice),
            try DesktopSpeechVoice.resolved(modelID: "soniox", voiceID: SonioxTTSCatalog.voices[0].providerVoiceID),
            .gemini(GeminiTTSCatalog.defaultVoice), .groq(GroqTTSCatalog.voices[0]),
            .speechmatics(SpeechmaticsTTSCatalog.voices[0]), .deepgram(DeepgramSpeechCatalog.voices[0])
        ]
        XCTAssertEqual(voices[0].capabilities.speedRange, AzureSpeechVoiceAPI.speedRange)
        XCTAssertEqual(voices[1].capabilities.speedRange, XAITTSAPI.speedRange)
        XCTAssertEqual(voices[2].capabilities.speedRange, CartesiaTTSAPI.speedRange)
        XCTAssertEqual(voices[3].capabilities.speedRange, SonioxTTSAPI.speedRange)
        let probe = CredentialProbe()
        for voice in voices {
            for speed in [0.25, 4.0] {
                do {
                    _ = try await DesktopSpeechSynthesis(session: session).synthesize(
                        source, voice: voice, options: VoiceSynthesisOptions(speed: speed, quality: .highest)
                    ) { try await probe.supply() }
                    XCTFail("An unsupported provider speed was accepted")
                } catch { XCTAssertTrue(error is VoiceSynthesisConfigurationError) }
            }
        }
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
    }

    func testDeepgramQuality_RequestsValidatesAndPublishesTheCapturedRealPCMRate() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic Deepgram quality.")
        let voice = DesktopSpeechVoice.deepgram(DeepgramSpeechCatalog.voices[0])
        for quality in VoiceSynthesisQuality.allCases {
            let rate = quality.neuralSampleRate
            let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: rate))
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), wav) }
            let actual = try await DesktopSpeechSynthesis(session: session).synthesize(
                source, voice: voice, options: VoiceSynthesisOptions(quality: quality)
            ) { "synthetic-key" }
            XCTAssertEqual(actual, wav)
            let request = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
            let items = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(items.first { $0.name == "sample_rate" }?.value, String(rate))
            XCTAssertEqual(items.first { $0.name == "container" }?.value, "wav")
            XCTAssertEqual(try DeepgramSpeechWAV.canonical(actual, sampleRate: rate).sampleRate, rate)
        }
    }

    func testAzureQuality_UsesTheRealFormatAndRetainsDocumentAndFragmentProsody() async throws {
        let voice = DesktopSpeechVoice.azureNeural(AzureNeuralVoiceCatalog.voices[0])
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "<break time='500ms'/>Synthetic.")
        for quality in VoiceSynthesisQuality.allCases {
            let rate = quality.neuralSampleRate
            let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: rate))
            StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), wav) }
            let actual = try await DesktopSpeechSynthesis(session: session).synthesize(
                source, voice: voice, options: VoiceSynthesisOptions(pitch: 2, useSSML: true, quality: quality)
            ) { "synthetic-key:eastus" }
            XCTAssertEqual(actual, wav)
            let sent = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
            XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Microsoft-OutputFormat"),
                           "riff-\(rate / 1000)khz-16bit-mono-pcm")
            let text = try XCTUnwrap(String(data: StubURLProtocol.body(of: sent), encoding: .utf8))
            XCTAssertTrue(text.contains(source.text))
            XCTAssertTrue(text.contains("pitch='+2st'"))
        }
        let probe = CredentialProbe()
        let document = try VoiceOutputSourceSnapshot(source: .typedText,
            text: VoiceSynthesisMarkup.wrapping("Synthetic document."))
        do {
            _ = try await DesktopSpeechSynthesis(session: session).synthesize(
                document, voice: voice, options: VoiceSynthesisOptions(speed: 1.2, useSSML: true, quality: .highest)
            ) { try await probe.supply() }
            XCTFail("Complete SSML document controls were discarded")
        } catch { XCTAssertEqual(error as? DesktopSpeechSynthesisError, .documentControls) }
        XCTAssertEqual(probe.count, 0)
    }

}

extension DesktopVoiceQualityTests {
    func testCartesiaAndSonioxQuality_UseTheirCanonicalRequestsAtAllThreeActualRates() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic rate capture.")
        let soniox = try DesktopSpeechVoice.resolved(
            modelID: "soniox", voiceID: SonioxTTSCatalog.voices[0].providerVoiceID)
        for voice in [DesktopSpeechVoice.cartesia(CartesiaTTSCatalog.defaultVoice), soniox] {
            for quality in VoiceSynthesisQuality.allCases {
                let rate = quality.sampleRate
                let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: rate))
                StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), wav) }
                let actual = try await DesktopSpeechSynthesis(session: session).synthesize(
                    source, voice: voice, options: VoiceSynthesisOptions(quality: quality),
                    accountInventory: nil, sonioxRegion: .europe, language: "en_GB"
                ) { "synthetic-key" }
                XCTAssertEqual(actual, wav)
                let request = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
                if case .cartesia = voice {
                    let expected = CartesiaTTSRequest(voiceID: voice.id, outputFormat: .wav(sampleRate: rate),
                        languageIdentifier: nil, content: source.text, speed: 1)
                    XCTAssertEqual(try normalizedBody(request),
                        try JSONSerialization.data(withJSONObject: expected.jsonBody(transcript: source.text),
                                                   options: .sortedKeys))
                } else {
                    let preset = try XCTUnwrap(SonioxTTSCatalog.voice(forID: voice.id))
                    let canonical = try SonioxTTSAPI.synthesisRequest(text: source.text, apiKey: "synthetic-key",
                        request: .init(language: SonioxTTSCatalog.languageCode(
                            forVoiceOutputIdentifier: "en_GB", content: source.text), voice: preset,
                            audioFormat: .wav, sampleRate: rate, speed: 1), region: .europe)
                    XCTAssertEqual(request.url, canonical.url)
                    XCTAssertEqual(try normalizedBody(request), try normalizedBody(canonical))
                }
            }
        }
    }

    func testWrongRatePCM_IsRejectedInsteadOfBeingRelabelledAsHighQuality() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic wrong rate.")
        let wav = try XCTUnwrap(PCMWaveWriter.wavData(pcm: pcm, sampleRate: 24_000))
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), wav) }
        let voices = [
            DesktopSpeechVoice.deepgram(DeepgramSpeechCatalog.voices[0]),
            .azureNeural(AzureNeuralVoiceCatalog.voices[0]), .cartesia(CartesiaTTSCatalog.defaultVoice),
            try DesktopSpeechVoice.resolved(modelID: "soniox", voiceID: SonioxTTSCatalog.voices[0].providerVoiceID)
        ]
        for voice in voices {
            do {
                _ = try await DesktopSpeechSynthesis(session: session).synthesize(
                    source, voice: voice, options: VoiceSynthesisOptions(quality: .highest)
                ) { "synthetic-key:eastus" }
                XCTFail("A mismatched PCM rate was relabelled")
            } catch {
                if case .deepgram = voice { XCTAssertTrue(error is DeepgramSpeechError) } else {
                    XCTAssertEqual(error as? DesktopSpeechSynthesisError, .invalidAudio)
                }
            }
        }
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, voices.count)
    }

    func testIncompatibleQualityAndPrecancelledWork_NeverReadCredentialsOrSend() async throws {
        let source = try VoiceOutputSourceSnapshot(source: .typedText, text: "Synthetic admission.")
        let preset = try XCTUnwrap(OpenAITTSCatalog.voices.first { !$0.supportsLegacyModels })
        let probe = CredentialProbe()
        for quality in [VoiceSynthesisQuality.high, .highest] {
            do {
                _ = try await DesktopSpeechSynthesis(session: session).synthesize(
                    source, voice: .openai(.mini, preset), options: VoiceSynthesisOptions(quality: quality)
                ) { try await probe.supply() }
                XCTFail("Quality silently changed the selected voice")
            } catch { XCTAssertEqual(error as? VoiceSynthesisConfigurationError, .unsupportedVoice) }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DesktopSpeechSynthesis(session: session).synthesize(
                source, voice: .deepgram(DeepgramSpeechCatalog.voices[0]),
                options: VoiceSynthesisOptions(quality: .highest)
            ) { try await probe.supply() }
        }
        do { _ = try await task.value; XCTFail("Cancelled quality work executed") } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        XCTAssertThrowsError(try VoiceOutputSourceSnapshot(source: .typedText, text: " \n "))
    }

    func testDeliveryGuidance_ReusesMacMarkupWithoutInventingProviderInstructionsOrFormats() throws {
        XCTAssertEqual(VoiceSynthesisMarkup.examples.count, 6)
        XCTAssertEqual(VoiceSynthesisMarkup.wrapping("Synthetic."), "<speak>Synthetic.</speak>")
        XCTAssertEqual(VoiceSynthesisMarkup.wrapping("<speak>Synthetic.</speak>"), "<speak>Synthetic.</speak>")
        let azure = DesktopSpeechVoice.azureNeural(AzureNeuralVoiceCatalog.voices[0])
        for example in VoiceSynthesisMarkup.examples {
            XCTAssertTrue(azure.deliveryGuidance.contains(example.text))
        }
        for voice in DesktopSpeechVoice.voices where !voice.capabilities.ssml {
            XCTAssertTrue(voice.deliveryGuidance.contains("not implemented"))
            XCTAssertFalse(voice.deliveryGuidance.contains("<prosody"))
        }
        for voice in DesktopSpeechVoice.voices {
            XCTAssertLessThan(voice.deliveryGuidance.utf8.count, 8_192)
            for quality in VoiceSynthesisQuality.allCases {
                switch voice {
                case .openai:
                    continue
                case .cartesia, .soniox:
                    XCTAssertEqual(voice.sampleRate(quality: quality), quality.sampleRate)
                case .deepgram, .azureNeural, .azureMAI:
                    XCTAssertEqual(voice.sampleRate(quality: quality), quality.neuralSampleRate)
                case .elevenlabs:
                    XCTAssertEqual(voice.sampleRate(quality: quality), 24_000)
                    XCTAssertEqual(voice.qualityTitle.contains("fixed format"), !voice.supportsQualityControls)
                default:
                    XCTAssertEqual(voice.sampleRate(quality: quality), voice.sampleRate)
                    XCTAssertTrue(voice.qualityTitle.contains("fixed format"))
                }
            }
        }
    }

    private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: StubURLProtocol.body(of: request)) as? [String: Any])
    }

    private func normalizedBody(_ request: URLRequest) throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonBody(request), options: .sortedKeys)
    }
}
