import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class SonioxDesktopContractTests: DeepgramSpeechStubTestCase {
    func testCanonicalVoices_LegacyModelsAndNativeCapabilitiesStayProviderBound() throws {
        let projected = VoiceAccountProvider.soniox.documentedPresets
        XCTAssertEqual(projected.map(\.id), SonioxTTSCatalog.voices.map(\.providerVoiceID))
        XCTAssertTrue(projected.allSatisfy(DesktopSpeechVoice.voices.contains))
        XCTAssertEqual(Set(projected.map(\.id)).count, SonioxTTSCatalog.voices.count)
        for voice in projected {
            for model in ["tts-rt-v1", "tts-rt-v1-preview", "tts-rt-v2", "soniox/tts-rt-v2"] {
                XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: model, voiceID: voice.id), voice)
            }
            XCTAssertEqual(voice.capabilities.nativeFlags, 1)
            XCTAssertEqual(voice.capabilities.speedRange, SonioxTTSAPI.speedRange)
            XCTAssertEqual(voice.modelID, SonioxTTSCatalog.defaultModel.rawValue)
            XCTAssertEqual(try VoiceOutputCredentialSlot(voice: voice).identifier, voice.apiKeyIdentifier)
        }
        let chosen = try XCTUnwrap(projected.first)
        for model in ["deepgram/aura-2", "azure/neural", "xai", "mistral/voxtral-mini-tts", "tts-rt-v99"] {
            XCTAssertThrowsError(try DesktopSpeechVoice.resolved(modelID: model, voiceID: chosen.id))
        }
        for voice in ["xai/eve", "deepgram/aura-2-thalia-en", "soniox/missing-clone"] {
            XCTAssertThrowsError(try DesktopSpeechVoice.resolved(modelID: "tts-rt-v2", voiceID: voice))
        }
        XCTAssertEqual(try DesktopSpeechVoice.resolved(modelID: nil, voiceID: chosen.id), chosen)
    }

    func testCanonicalRequests_KeepRegionalKeyOnlyInHeaderAndPreserveAppleHTTPContract() async throws {
        let builtIn = SonioxTTSCatalog.defaultVoice(for: SonioxTTSCatalog.defaultModel)
        let selected = SonioxTTSRequest(language: "fr-FR", voice: builtIn, audioFormat: .wav,
                                       sampleRate: 24_000, speed: 1.25)
        let audio = DeepgramSpeechFixture.canonicalWAV(pcm: pcm)
        StubURLProtocol.handler = { .respond(DeepgramSpeechFixture.response($0), audio) }
        for region in SonioxTTSRegion.allCases {
            let canonical = try SonioxTTSAPI.synthesisRequest(
                text: "Synthetic shared contract.", apiKey: "synthetic-key", request: selected, region: region)
            let result = try await SonioxTTSAPI(session: session, region: region).synthesize(
                text: "Synthetic shared contract.", apiKey: "synthetic-key", request: selected)
            XCTAssertEqual(result, audio)
            let actual = try XCTUnwrap(StubURLProtocol.recordedRequests.last)
            XCTAssertEqual(actual.url, region.speakEndpoint)
            XCTAssertEqual(actual.httpMethod, canonical.httpMethod)
            let body = StubURLProtocol.body(of: actual)
            XCTAssertEqual(
                try JSONDecoder().decode([String: AnyCodable].self, from: body),
                try JSONDecoder().decode([String: AnyCodable].self, from: XCTUnwrap(canonical.httpBody))
            )
            XCTAssertEqual(actual.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
            XCTAssertFalse(try XCTUnwrap(actual.url?.absoluteString).contains("synthetic-key"))
            let encodedBody = try XCTUnwrap(String(bytes: body, encoding: .utf8))
            XCTAssertFalse(encodedBody.contains("synthetic-key"))
            let listing = try SonioxTTSAPI.voiceListRequest(
                apiKey: "synthetic-key", region: region, cursor: "synthetic + / cursor")
            XCTAssertEqual(listing.url?.host, region.apiHost)
            XCTAssertEqual(listing.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-key")
            let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(listing.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems?.first { $0.name == "cursor" }?.value, "synthetic + / cursor")
        }
    }

    func testRegionAndLanguage_UnknownTransferValuesAreRetainedButNotOperational() throws {
        XCTAssertEqual(SonioxTTSRegion.migrated(from: "future-region"), .unitedStates)
        XCTAssertNil(SonioxTTSRegion.recognized(from: "future-region"))
        XCTAssertEqual(SonioxTTSRegion.recognized(from: "europe"), .europe)
        XCTAssertEqual(SonioxTTSRegion.recognized(from: nil), .unitedStates)
        let configuration = try DesktopConfiguration(values: [
            SonioxVoicePreference.regionKey: AnyCodable(.string("future-region"))
        ])
        let field = try XCTUnwrap(DesktopConfiguration.fields.first { $0.key == SonioxVoicePreference.regionKey })
        let choices = try XCTUnwrap(configuration.serializedChoices(for: field))
        XCTAssertTrue(choices.contains("future-region\tUnsupported stored region"))
        for region in SonioxTTSRegion.allCases { XCTAssertTrue(choices.contains("\(region.rawValue)\t")) }
        XCTAssertEqual(configuration.values[SonioxVoicePreference.regionKey], AnyCodable(.string("future-region")))
        XCTAssertThrowsError(try SonioxVoicePreference.string(
            SonioxVoicePreference.regionKey, in: [SonioxVoicePreference.regionKey: AnyCodable(.bool(true))]))
        XCTAssertThrowsError(try SonioxVoicePreference.validateLanguage("future-unsupported-locale"))
        try SonioxVoicePreference.validateLanguage("fr-FR")
        try SonioxVoicePreference.validateLanguage(nil)
    }

    func testUnsupportedControls_RejectBeforeCredentialAndHTTP() async throws {
        let voice = try XCTUnwrap(VoiceAccountProvider.soniox.documentedPresets.first)
        let unsupported = try [
            VoiceSynthesisOptions(speed: 0.6), .init(speed: 1.4), .init(pitch: 1), .init(useSSML: true)
        ]
        for options in unsupported {
            do {
                _ = try await DesktopSpeechSynthesis(session: session).synthesize(
                    .init(source: .typedText, text: "Synthetic invalid controls."), voice: voice, options: options,
                    credential: { XCTFail("Unsupported controls read credentials"); return "synthetic-key" })
                XCTFail("Unsupported controls admitted")
            } catch { XCTAssertTrue(error is VoiceSynthesisConfigurationError) }
        }
        XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
        for speed in [SonioxTTSAPI.speedRange.lowerBound, SonioxTTSAPI.speedRange.upperBound] {
            XCTAssertNoThrow(try VoiceSynthesisOptions(speed: speed).validate(for: voice.capabilities))
        }
    }
}
