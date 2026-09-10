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
        // Speechmatics moved to the shared SpeakCore client, so the iPhone can
        // now stream every remote model the Mac can.
        XCTAssertTrue(visibleIDs.contains(SpeechmaticsRealtime.liveCatalogID))
        XCTAssertEqual(visibleIDs, Set(ModelCatalog.remoteLiveTranscription.map(\.id)))
        XCTAssertTrue(visibleIDs.contains(OpenAITranscriptionModels.gptLiveTranscribeStreamingCatalogID))
        XCTAssertTrue(visibleIDs.contains(XAIVoiceModels.thinkFast2CatalogID))
        XCTAssertTrue(visibleIDs.contains(XAISpeechToText.liveCatalogID))
    }

    func testRemoteBatchPicker_omitsProvidersWithoutAnIOSUploadPath() {
        let visibleProviders = Set(AppSettings.supportedBatchModels.map { option in
            String(option.id.prefix { $0 != "/" })
        })

        // Apple's on-device SpeechAnalyzer entries need no upload path and are
        // listed whenever the runtime supports one of the analyzer engines
        // (SpeechTranscriber needs Apple Intelligence; DictationTranscriber
        // needs OS 26), so the expected provider set depends on the runtime.
        var expectedProviders: Set<String> = [
            "cartesia", "gladia", "google", "meta", "openai", "xai"
        ]
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

    /// xAI's dedicated speech-to-text endpoint uploads through the shared
    /// client with the xAI key; the Grok Voice streaming identifier shares the
    /// `xai/` prefix but has no file mode at all.
    func testXAIBatchIsSelectableAndUsesItsOwnUploadRouteAndKey() {
        XCTAssertTrue(
            AppSettings.supportedBatchModels.contains { $0.id == XAISpeechToText.batchCatalogID }
        )
        XCTAssertEqual(
            IOSBatchTranscriptionRoute.route(for: XAISpeechToText.batchCatalogID),
            .xai
        )
        XCTAssertEqual(
            IOSBatchTranscriptionRoute.route(for: " xai/speech-to-text "),
            .xai
        )
        XCTAssertEqual(
            ModelCredentialResolver.requirement(
                for: XAISpeechToText.batchCatalogID,
                purpose: .batchTranscription
            ),
            .apiKey(identifier: "xai.apiKey", providerName: "xAI")
        )
        // The prompt is derived from that requirement, so it names xAI rather
        // than inheriting the OpenRouter wording.
        XCTAssertEqual(
            SettingsView.batchAPIKeyPrompt(for: XAISpeechToText.batchCatalogID),
            "Add your xAI API key below to use this model."
        )
    }

    /// Gladia batch reuses the `gladia.apiKey` this app already stores for live
    /// Solaria, so it is selectable and resolves that credential rather than
    /// falling back to the OpenRouter key.
    func testGladiaBatchIsSelectableAndResolvesTheGladiaKey() {
        XCTAssertTrue(AppSettings.supportedBatchModels.contains { $0.id == GladiaBatchClient.catalogID })
        XCTAssertEqual(IOSBatchTranscriptionRoute.route(for: GladiaBatchClient.catalogID), .gladia)
        XCTAssertEqual(IOSBatchTranscriptionRoute.route(for: " gladia/solaria-1 "), .gladia)
        XCTAssertEqual(
            ModelCredentialResolver.requirement(
                for: GladiaBatchClient.catalogID, purpose: .batchTranscription),
            .apiKey(identifier: AppSettings.gladiaKeyID, providerName: "Gladia"))
    }

    /// Documented platform restriction: Speechmatics batch stays macOS-only.
    ///
    /// This app now stores `speechmatics.apiKey` for the live provider, so the
    /// original reason for hiding the batch entry (no credential field) no
    /// longer holds. The remaining one does: `IOSBatchTranscriptionRoute` has
    /// no Speechmatics case, so a selectable entry would fall through to the
    /// OpenRouter route and upload to the wrong service. It is hidden until an
    /// iOS upload path exists — the same treatment every other provider
    /// without one gets.
    /// See Docs/batch-transcription-providers.md.
    func testSpeechmaticsBatchIsHiddenOnIOSBecauseThereIsNoUploadRoute() {
        XCTAssertTrue(ModelCatalog.batchTranscription.contains {
            SpeechmaticsBatchClient.catalogIDs.contains($0.id)
        })
        XCTAssertFalse(AppSettings.supportedBatchModels.contains {
            SpeechmaticsBatchClient.catalogIDs.contains($0.id)
        })
        XCTAssertEqual(
            ModelCredentialResolver.requirement(
                for: SpeechmaticsBatchClient.enhancedCatalogID, purpose: .batchTranscription),
            .apiKey(identifier: "speechmatics.apiKey", providerName: "Speechmatics"))
        // No dedicated route exists, which is exactly why the entry stays
        // hidden: routing it would send Speechmatics audio to OpenRouter.
        for id in SpeechmaticsBatchClient.catalogIDs {
            XCTAssertEqual(IOSBatchTranscriptionRoute.route(for: id), .openRouter)
        }
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
