#if os(iOS)
import SpeakCore
import SwiftUI
import XCTest

@testable import SpeakiOSLib

@MainActor
final class PlatformFeatureVisibilityTests: XCTestCase {
    func testKeyboardFeatureEnvironmentDefaultsOff() {
        XCTAssertFalse(EnvironmentValues().iOSKeyboardEnabled)
    }

    func testRemoteLivePicker_omitsProvidersWithoutAnIOSImplementation() {
        let visibleModels = AppSettings.supportedLiveModels
        let visibleIDs = Set(visibleModels.map(\.id))

        XCTAssertFalse(visibleModels.isEmpty)
        XCTAssertTrue(visibleModels.allSatisfy { option in
            LiveTranscriptionRouting.route(for: option.id)?.isSupportedOnIOS == true
        })
        XCTAssertTrue(
            ModelCatalog.remoteLiveTranscription
                .filter { LiveTranscriptionRouting.route(for: $0.id)?.isSupportedOnIOS == false }
                .allSatisfy { !visibleIDs.contains($0.id) }
        )
        XCTAssertFalse(visibleIDs.contains { $0.hasPrefix("speechmatics/") })
        XCTAssertTrue(visibleIDs.contains(OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID))
        XCTAssertTrue(visibleIDs.contains(XAIVoiceModels.thinkFast2CatalogID))
    }

    func testRemoteBatchPicker_omitsProvidersWithoutAnIOSUploadPath() {
        let visibleProviders = Set(AppSettings.supportedBatchModels.map { option in
            String(option.id.prefix { $0 != "/" })
        })

        // Apple's on-device SpeechAnalyzer entries need no upload path and are
        // listed whenever the runtime supports one of the analyzer engines
        // (SpeechTranscriber needs Apple Intelligence; DictationTranscriber
        // needs OS 26), so the expected provider set depends on the runtime.
        var expectedProviders: Set<String> = ["cartesia", "google", "meta", "openai"]
        if AppleLocalModels.supportsSpeechTranscriber || AppleLocalModels.supportsDictationTranscriber {
            expectedProviders.insert("apple")
        }
        XCTAssertEqual(visibleProviders, expectedProviders)

        // Meta Muse uploads through MetaMuseBatchClient on iOS, so it is listed.
        XCTAssertTrue(AppSettings.supportedBatchModels.contains { $0.id == MetaMuseVoiceTranscribe.batchCatalogID })
        // Gemini 3.5 Transcribe uploads through the shared
        // GeminiInteractionsClient on iOS, so it is listed too (issue #862).
        XCTAssertTrue(AppSettings.supportedBatchModels.contains { $0.id == GeminiTranscribeModels.batchCatalogID })
        XCTAssertTrue(
            AppSettings.supportedBatchModels.contains {
                $0.id == OpenAITranscriptionModels.gptTranscribeCatalogID
            }
        )
        XCTAssertTrue(
            AppSettings.openAIBatchModelIDs.contains(OpenAITranscriptionModels.gptTranscribeCatalogID)
        )
    }

    /// The `google/` prefix is shared by two different upload paths, so the
    /// routing has to split them: Gemini 3.5 Transcribe goes to Google's own
    /// Interactions API, the Gemini 2.x entries stay on OpenRouter.
    func testCartesiaBatchIsSelectableAndUsesItsOwnUploadRoute() {
        XCTAssertTrue(AppSettings.supportedBatchModels.contains { $0.id == CartesiaBatchClient.catalogID })
        XCTAssertEqual(IOSBatchTranscriptionRoute.route(for: CartesiaBatchClient.catalogID), .cartesia)
        XCTAssertEqual(IOSBatchTranscriptionRoute.route(for: " cartesia/ink-whisper "), .cartesia)
    }

    func testBatchRouting_sendsGemini35ToItsOwnClientAndLeavesOpenRouterModelsAlone() {
        XCTAssertEqual(
            IOSBatchTranscriptionRoute.route(for: GeminiTranscribeModels.batchCatalogID),
            .gemini
        )
        XCTAssertEqual(IOSBatchTranscriptionRoute.route(for: "google/gemini-2.0-flash-001"), .openRouter)
        XCTAssertEqual(
            IOSBatchTranscriptionRoute.route(for: MetaMuseVoiceTranscribe.batchCatalogID),
            .metaMuse
        )
        XCTAssertEqual(
            IOSBatchTranscriptionRoute.route(for: OpenAITranscriptionModels.gptTranscribeCatalogID),
            .openAI
        )
        XCTAssertEqual(
            IOSBatchTranscriptionRoute.route(for: AppleLocalModels.speechTranscriberModelID),
            .appleSpeechAnalyzer
        )
    }

    /// `batchAPIKey(for:)` reads the canonical credential mapping, so the
    /// Gemini branch is handed the Google key rather than the OpenRouter one.
    func testBatchCredentials_splitDirectProvidersFromOpenRouter() {
        let expected = [
            GeminiTranscribeModels.batchCatalogID: "google.apiKey",
            "google/gemini-2.0-flash-001": "openrouter.apiKey",
            MetaMuseVoiceTranscribe.batchCatalogID: "meta.apiKey",
            OpenAITranscriptionModels.gptTranscribeCatalogID: "openai.apiKey"
        ]
        for (model, identifier) in expected {
            guard case .apiKey(let resolved, _) = ModelCredentialResolver.requirement(
                for: model, purpose: .batchTranscription
            ) else {
                return XCTFail("\(model) must require an API key")
            }
            XCTAssertEqual(resolved, identifier, "\(model) must resolve to \(identifier)")
        }
        XCTAssertEqual(
            ModelCredentialResolver.requirement(
                for: AppleLocalModels.speechTranscriberModelID, purpose: .batchTranscription
            ),
            .notRequired
        )
    }

    func testPaddedBatchModelsKeepRoutingAndCredentialsInAgreement() {
        let cases: [String: (IOSBatchTranscriptionRoute, String)] = [
            GeminiTranscribeModels.batchCatalogID: (.gemini, "google.apiKey"),
            "google/gemini-2.0-flash-001": (.openRouter, "openrouter.apiKey"),
            MetaMuseVoiceTranscribe.batchCatalogID: (.metaMuse, "meta.apiKey"),
            OpenAITranscriptionModels.gptTranscribeCatalogID: (.openAI, "openai.apiKey")
        ]
        for (model, expected) in cases {
            let padded = " \n\t" + model + " \r\n"
            XCTAssertEqual(IOSBatchTranscriptionRoute.route(for: padded), expected.0)
            guard case .apiKey(let identifier, _) = ModelCredentialResolver.requirement(
                for: padded, purpose: .batchTranscription
            ) else {
                return XCTFail("Expected a credential for \(model)")
            }
            XCTAssertEqual(identifier, expected.1)
        }
    }

    func testOpenClawVoiceOutput_ExposesSharedSonioxCatalogueAndCredential() {
        XCTAssertTrue(VoiceOutputProvider.allCases.contains(.soniox))
        XCTAssertEqual(VoiceOutputProvider.soniox.apiKeyIdentifier, "soniox.apiKey")
        XCTAssertEqual(
            Set(OpenClawSettings.sonioxBuiltInVoices.map(\.providerVoiceID)),
            Set(SonioxTTSCatalog.voices.map(\.providerVoiceID))
        )
    }
}
#endif
