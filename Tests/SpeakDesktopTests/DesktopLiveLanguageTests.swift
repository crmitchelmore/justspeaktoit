import Foundation
import SpeakCore
import SpeakDesktop
import XCTest

final class DesktopLiveLanguageTests: XCTestCase {
    private let supported = "deepgram/nova-3-streaming"
    private let unsupported = AssemblyAIModels.universal35ProStreamingID
    private let options = DesktopPostProcessing.Options(mode: .disabled)

    func testOriginalCapabilityInitializerRetainsItsExactFunctionSignature() {
        let original: (Set<SpeedModeID>, TimeInterval) -> LiveModelCapabilities =
            LiveModelCapabilities.init(supportedSpeedModes:postStopFinalizeBudget:)
        let capabilities = original([.instant, .livePolish], 2)
        XCTAssertEqual(capabilities.supportedSpeedModes, [.instant, .livePolish])
        XCTAssertEqual(capabilities.postStopFinalizeBudget, 2)
        XCTAssertFalse(capabilities.supportsLanguageHint)
    }

    func testCanonicalHintsAreConservativeAndProjectionRequiresHostForwarding() {
        let supportedIDs = [
            supported, "deepgram/flux-general-multi-streaming", SpeechmaticsRealtime.liveCatalogID,
            "elevenlabs/scribe-v2-streaming", "soniox/stt-rt-v5-streaming", XAISpeechToText.liveCatalogID,
            "openai/gpt-realtime-whisper-streaming", "openai/gpt-4o-mini-transcribe-streaming",
            "openai/gpt-4o-transcribe-streaming", OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID,
            "gladia/solaria-1-streaming", RevAIStreaming.liveCatalogID
        ]
        for identifier in supportedIDs {
            XCTAssertTrue(ModelCatalog.liveCapabilities(for: identifier).supportsLanguageHint, identifier)
        }
        // English-only or detect-only wire contracts: Flux English, AssemblyAI,
        // Cartesia Ink-2 and Voxtral carry no language field.
        for identifier in [
            unsupported, "deepgram/flux-general-en-streaming", "cartesia/ink-2-streaming",
            MistralVoxtralRealtime.liveCatalogID, "future/unknown-streaming"
        ] {
            XCTAssertFalse(ModelCatalog.liveCapabilities(for: identifier).supportsLanguageHint, identifier)
        }
        XCTAssertFalse(LiveModelCapabilities(supportedSpeedModes: [.instant]).supportsLanguageHint)
        let projected = Set(DesktopLiveTranscription.liveModels.filter {
            ModelCatalog.liveCapabilities(for: $0.id).supportsLanguageHint
        }.map(\.id))
        XCTAssertEqual(DesktopLiveTranscription.languageHintModelIDs, projected)
        XCTAssertEqual(DesktopProfileCapabilities.shared.liveLanguageModelIDs, projected)

        var host = DesktopProfileCapabilities(
            batchModels: [], liveModels: DesktopLiveTranscription.liveModels, polishModels: []
        )
        XCTAssertFalse(host.supportsLiveLanguage(for: supported), "A protocol capability does not wire the host")
        host.liveLanguageModelIDs = [supported, unsupported]
        XCTAssertTrue(host.supportsLiveLanguage(for: supported))
        XCTAssertFalse(host.supportsLiveLanguage(for: unsupported), "Host lists cannot override the wire contract")
        host.supportsLiveLanguage = true
        XCTAssertFalse(
            host.supportsLiveLanguage(for: unsupported), "The legacy flag must not advertise unsupported hints"
        )
        host.liveModels = []
        XCTAssertFalse(host.supportsLiveLanguage(for: supported), "Unavailable routes cannot accept profile overrides")
    }

    func testSupportedOverrideUsesItsOwnCapabilityInsteadOfUnsupportedDefault() {
        let profile = languageProfile(model: supported)
        let session = resolve(profile, defaultModel: unsupported)
        XCTAssertEqual(session.modelIdentifier, supported)
        XCTAssertEqual(session.language, "fr_FR")
        XCTAssertTrue(session.limitations.isEmpty)
        XCTAssertTrue(DesktopProfileSessionResolver.limitations(of: profile, capabilities: .shared).isEmpty)
    }

    func testUnsupportedOverridesWarnEvenWhenAppDefaultSupportsHint() {
        for identifier in [unsupported, "deepgram/flux-general-en-streaming"] {
            let profile = languageProfile(model: identifier)
            let session = resolve(profile, defaultModel: supported)
            XCTAssertEqual(session.modelIdentifier, identifier)
            XCTAssertNil(session.language)
            let expected = [DesktopProfileLimitation.languageUnavailableForLiveModel(languageIdentifier: "fr_FR")]
            XCTAssertEqual(session.limitations, expected)
            XCTAssertEqual(DesktopProfileSessionResolver.limitations(of: profile, capabilities: .shared), expected)
            XCTAssertTrue(session.canRecord)
            XCTAssertFalse(expected[0].message.contains("detect"), "English-only models do not auto-detect languages")
        }
    }

    func testAutomaticAndMissingLanguageNeverClaimAnUnsupportedOverride() {
        for identifier in [supported, unsupported, "deepgram/flux-general-en-streaming"] {
            for language in [nil, "", "  ", TranscriptionLanguageCatalog.automaticIdentifier] as [String?] {
                var profile = languageProfile(model: identifier)
                profile.languageIdentifier = language
                let session = resolve(profile, defaultModel: unsupported)
                XCTAssertNil(session.language)
                XCTAssertTrue(session.limitations.isEmpty)
                XCTAssertTrue(DesktopProfileSessionResolver.limitations(of: profile, capabilities: .shared).isEmpty)
            }
        }
        let inherited = DictationProfile(name: "Automatic", languageIdentifier: "automatic")
        XCTAssertTrue(DesktopProfileSessionResolver.limitations(of: inherited, capabilities: .shared).isEmpty)
    }

    func testInheritedModelEditorIsConditionalButRecordingUsesActualDefault() {
        let profile = DictationProfile(name: "Inherited", languageIdentifier: "fr_FR")
        XCTAssertEqual(
            DesktopProfileSessionResolver.limitations(of: profile, capabilities: .shared),
            [.languageDependsOnAppModel(languageIdentifier: "fr_FR")]
        )
        let accepts = resolve(profile, defaultModel: supported)
        XCTAssertEqual(accepts.language, "fr_FR")
        XCTAssertTrue(accepts.limitations.isEmpty)
        let ignores = resolve(profile, defaultModel: unsupported)
        XCTAssertNil(ignores.language)
        XCTAssertEqual(ignores.limitations, [.languageUnavailableForLiveModel(languageIdentifier: "fr_FR")])

        var narrowed = DesktopProfileCapabilities.shared
        narrowed.liveModels = narrowed.liveModels.filter { narrowed.supportsLiveLanguage(for: $0.id) }
        XCTAssertTrue(DesktopProfileSessionResolver.limitations(of: profile, capabilities: narrowed).isEmpty)
    }

    func testRecordedSnapshotKeepsLanguageAndModelAfterProfileAndDefaultsChange() throws {
        var profile = languageProfile(model: supported)
        var defaultModel = unsupported
        let snapshot = resolve(profile, defaultModel: defaultModel)
        profile.languageIdentifier = "de_DE"
        profile.transcriptionModelID = "deepgram/flux-general-en-streaming"
        defaultModel = OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID
        let next = resolve(profile, defaultModel: defaultModel)
        XCTAssertNil(next.language)
        XCTAssertNotEqual(next.modelIdentifier, snapshot.modelIdentifier)

        let factory = AssemblyAISocketFactory()
        let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: snapshot.modelIdentifier, apiKey: "synthetic", language: snapshot.language,
            makeConnection: { factory.make($0) }
        ))
        client.start(onTranscript: { _, _ in }, onError: { XCTFail("Unexpected error: \($0)") })
        defer { client.cancel() }
        let url = try XCTUnwrap(factory.requests.first?.url)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "model" }?.value, "nova-3")
        XCTAssertEqual(query.first { $0.name == "language" }?.value, "fr")
        XCTAssertEqual(snapshot.language, "fr_FR", "The immutable record retains the requested locale")
    }
}

private extension DesktopLiveLanguageTests {
    func languageProfile(model: String) -> DictationProfile {
        DictationProfile(
            name: "French", transcriptionModelID: model, languageIdentifier: "fr_FR",
            transcriptionRouting: .remoteStreaming
        )
    }

    func resolve(_ profile: DictationProfile, defaultModel: String) -> DesktopProfileSession {
        DesktopProfileSessionResolver.resolve(
            profile: profile, defaultModel: defaultModel, defaultPostProcessing: options, capabilities: .shared
        )
    }
}
