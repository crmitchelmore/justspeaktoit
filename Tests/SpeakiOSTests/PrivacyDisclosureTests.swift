#if os(iOS)
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib

/// The privacy screen has to describe the user's *effective* workflow, and the
/// voice-output disclosure has to name every provider that can receive the text
/// it speaks (issue #850). Both are projections of the shared catalogues, so
/// these tests pin the projection rather than any hand-written copy.
final class PrivacyDisclosureTests: XCTestCase {

    // MARK: - Fixtures

    private func inputs(
        usesBatchTranscription: Bool = false,
        liveModel: String = AppleLocalModels.speechTranscriberModelID,
        batchModel: String = ModelCatalog.defaultBatchTranscriptionModel,
        postProcessingEnabled: Bool = false,
        postProcessingModel: String = ModelCatalog.defaultPostProcessingModel,
        voiceOutputEnabled: Bool = false,
        voiceOutputProvider: VoiceOutputProvider = .soniox,
        analyzerFallbackAllowed: Bool = false
    ) -> PrivacyWorkflowInputs {
        var value = PrivacyWorkflowInputs(
            usesBatchTranscription: usesBatchTranscription,
            liveTranscriptionModelID: liveModel,
            batchTranscriptionModelID: batchModel,
            postProcessingEnabled: postProcessingEnabled,
            postProcessingModelID: postProcessingModel,
            voiceOutputEnabled: voiceOutputEnabled,
            voiceOutputProvider: voiceOutputProvider
        )
        value.appleSpeechAnalyzerFallbackAllowed = analyzerFallbackAllowed
        return value
    }

    // MARK: - Transcription

    func testSpeechAnalyzerLiveModelStaysOnDevice() {
        let summary = PrivacyWorkflowSummary.make(inputs(liveModel: AppleLocalModels.speechTranscriberModelID))

        XCTAssertEqual(summary.transcription.destination, .onDevice)
        XCTAssertFalse(summary.transcription.isConditionalCloud)
        XCTAssertEqual(summary.transcription.destinationLabel, "On device")
        XCTAssertFalse(summary.transcription.destination.leavesDevice)
        XCTAssertTrue(
            summary.transcription.detail.contains("on this device"),
            "On-device transcription must say the audio stays on the device: \(summary.transcription.detail)"
        )
    }

    func testLegacyAppleSpeechDisclosesConditionalCloudFallback() {
        let summary = PrivacyWorkflowSummary.make(inputs(liveModel: AppleLocalModels.legacySpeechModelID))

        XCTAssertEqual(summary.transcription.destination, .cloud(providerName: "Apple"))
        XCTAssertTrue(summary.transcription.isConditionalCloud)
        XCTAssertEqual(summary.transcription.destinationLabel, "On device or Apple")
        XCTAssertTrue(summary.transcription.destination.leavesDevice)
        XCTAssertEqual(summary.activeRecipients, ["Apple"])
        XCTAssertTrue(summary.transcription.detail.contains("may be sent to Apple"))
        XCTAssertFalse(summary.transcription.detail.contains("it is not uploaded"))
    }

    func testSpeechAnalyzerBatchModelsHaveNoConditionalCloudRecipient() {
        for model in [AppleLocalModels.speechTranscriberModelID, AppleLocalModels.dictationTranscriberModelID] {
            let summary = PrivacyWorkflowSummary.make(inputs(usesBatchTranscription: true, batchModel: model))
            XCTAssertEqual(summary.transcription.destination, .onDevice)
            XCTAssertTrue(summary.activeRecipients.isEmpty)
            XCTAssertFalse(summary.transcription.detail.contains("servers"))
        }
    }

    func testConditionalAppleRecipientIsListedAlongsideEnabledTextProviders() {
        let summary = PrivacyWorkflowSummary.make(inputs(
            liveModel: " \n" + AppleLocalModels.legacySpeechModelID + " ",
            postProcessingEnabled: true, voiceOutputEnabled: true, voiceOutputProvider: .soniox
        ))
        XCTAssertEqual(summary.activeRecipients, ["Apple", "OpenRouter", VoiceOutputProvider.soniox.displayName])
    }

    func testLiveSpeechAnalyzerDisclosesItsPermittedLegacyFallback() {
        for model in [AppleLocalModels.speechTranscriberModelID, AppleLocalModels.dictationTranscriberModelID] {
            let summary = PrivacyWorkflowSummary.make(inputs(liveModel: model, analyzerFallbackAllowed: true))
            XCTAssertEqual(summary.transcription.destination, .cloud(providerName: "Apple"))
            XCTAssertEqual(summary.activeRecipients, ["Apple"])
        }
    }

    func testPersistedLegacyBatchIDDisclosesTheIOSOpenRouterRoute() {
        let summary = PrivacyWorkflowSummary.make(inputs(
            usesBatchTranscription: true, batchModel: AppleLocalModels.legacySpeechModelID
        ))
        XCTAssertEqual(summary.transcription.destination, .cloud(providerName: "OpenRouter"))
        XCTAssertEqual(IOSBatchTranscriptionRoute.route(for: AppleLocalModels.legacySpeechModelID), .openRouter)
    }

    func testCloudLiveModelNamesItsProvider() {
        let summary = PrivacyWorkflowSummary.make(inputs(liveModel: "deepgram/nova-3-streaming"))

        XCTAssertEqual(summary.transcription.destination, .cloud(providerName: "Deepgram"))
        XCTAssertTrue(summary.transcription.detail.contains("Deepgram"))
        XCTAssertTrue(summary.transcription.destination.leavesDevice)
    }

    /// Every live provider the iOS build supports must resolve to a named
    /// destination, so a newly supported provider cannot ship undisclosed.
    func testEverySupportedLiveProviderResolvesToItsOwnDestination() {
        for option in AppSettings.supportedLiveModels {
            guard let route = LiveTranscriptionRouting.route(for: option.id) else {
                XCTFail("No route for catalogued live model \(option.id)")
                continue
            }
            let summary = PrivacyWorkflowSummary.make(inputs(liveModel: option.id))
            XCTAssertEqual(
                summary.transcription.destination,
                .cloud(providerName: route.provider.displayName),
                "\(option.id) must disclose \(route.provider.displayName)"
            )
        }
    }

    func testBatchModeUsesTheBatchModelProvider() {
        let summary = PrivacyWorkflowSummary.make(
            inputs(
                usesBatchTranscription: true,
                liveModel: "deepgram/nova-3-streaming",
                batchModel: ModelCatalog.defaultBatchTranscriptionModel
            )
        )

        XCTAssertNotEqual(
            summary.transcription.destination,
            .cloud(providerName: "Deepgram"),
            "Batch mode must not disclose the inactive live provider"
        )
        XCTAssertEqual(
            summary.transcription.destination,
            .cloud(providerName: "OpenRouter"),
            "The default batch model is routed through OpenRouter"
        )
    }

    // MARK: - Post-processing

    func testPostProcessingOffSendsNothing() {
        let summary = PrivacyWorkflowSummary.make(inputs(postProcessingEnabled: false))

        XCTAssertEqual(summary.postProcessing.destination, .disabled)
        XCTAssertEqual(summary.postProcessing.destinationLabel, "Off")
        XCTAssertFalse(summary.postProcessing.destination.leavesDevice)
    }

    func testPostProcessingOnDisclosesOpenRouter() {
        let summary = PrivacyWorkflowSummary.make(inputs(postProcessingEnabled: true))

        XCTAssertEqual(summary.postProcessing.destination, .cloud(providerName: "OpenRouter"))
        XCTAssertTrue(summary.postProcessing.detail.contains("OpenRouter"))
    }

    func testLocalPostProcessingModelStaysOnDevice() {
        let summary = PrivacyWorkflowSummary.make(
            inputs(
                postProcessingEnabled: true,
                postProcessingModel: "local/post-processing/example"
            )
        )

        XCTAssertEqual(summary.postProcessing.destination, .onDevice)
    }

    // MARK: - Voice output

    func testEveryVoiceOutputProviderIsDisclosedWhenSelected() {
        for provider in VoiceOutputProvider.allCases {
            let summary = PrivacyWorkflowSummary.make(
                inputs(voiceOutputEnabled: true, voiceOutputProvider: provider)
            )

            XCTAssertEqual(
                summary.voiceOutput.destination,
                .cloud(providerName: provider.displayName),
                "Selecting \(provider.displayName) must disclose it as the recipient"
            )
            XCTAssertTrue(
                summary.voiceOutput.detail.contains(provider.displayName),
                "Voice-output detail must name \(provider.displayName): \(summary.voiceOutput.detail)"
            )
        }
    }

    func testVoiceOutputOffStillNamesTheProviderItWouldUse() {
        let summary = PrivacyWorkflowSummary.make(
            inputs(voiceOutputEnabled: false, voiceOutputProvider: .deepgram)
        )

        XCTAssertEqual(summary.voiceOutput.destination, .disabled)
        XCTAssertTrue(summary.voiceOutput.detail.contains(VoiceOutputProvider.deepgram.displayName))
    }

    /// The regression from issue #850: the disclosure named Soniox only, while
    /// Deepgram was equally selectable.
    func testVoiceOutputDisclosureCoversTheWholeCatalogue() {
        XCTAssertEqual(
            PrivacyWorkflowSummary.voiceOutputRecipients,
            VoiceOutputProvider.allCases.map(\.displayName)
        )

        let disclosure = PrivacyWorkflowSummary.voiceOutputDisclosure
        for provider in VoiceOutputProvider.allCases {
            XCTAssertTrue(
                disclosure.contains(provider.displayName),
                "Voice-output disclosure omits \(provider.displayName): \(disclosure)"
            )
        }
        XCTAssertTrue(PrivacyWorkflowSummary.textDisclosure.contains("OpenRouter"))
    }

    // MARK: - Active recipients

    func testActiveRecipientsListsEveryCloudHopOnce() {
        let summary = PrivacyWorkflowSummary.make(
            inputs(
                liveModel: "deepgram/nova-3-streaming",
                postProcessingEnabled: true,
                voiceOutputEnabled: true,
                voiceOutputProvider: .deepgram
            )
        )

        // Deepgram receives both the audio and the spoken text, but is listed once.
        XCTAssertEqual(summary.activeRecipients, ["Deepgram", "OpenRouter", "Deepgram Aura"])
    }

    func testFullyOnDeviceWorkflowHasNoRecipients() {
        let summary = PrivacyWorkflowSummary.make(inputs())

        XCTAssertTrue(summary.activeRecipients.isEmpty)
    }

    // MARK: - Settings adapter

    @MainActor
    func testSummaryFollowsAppSettings() throws {
        let suiteName = "PrivacyDisclosureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults, loadsSecureStorage: false)
        settings.selectedModel = AppleLocalModels.speechTranscriberModelID
        settings.transcriptionMode = .streaming
        settings.postProcessingEnabled = false

        var summary = PrivacyWorkflowSummary.make(
            settings: settings,
            voiceOutputEnabled: false,
            voiceOutputProvider: .soniox
        )
        XCTAssertEqual(summary.transcription.destination, .cloud(providerName: "Apple"))
        XCTAssertEqual(summary.postProcessing.destination, .disabled)

        settings.selectedModel = "deepgram/nova-3-streaming"
        settings.postProcessingEnabled = true

        summary = PrivacyWorkflowSummary.make(
            settings: settings,
            voiceOutputEnabled: true,
            voiceOutputProvider: .deepgram
        )
        XCTAssertEqual(summary.transcription.destination, .cloud(providerName: "Deepgram"))
        XCTAssertEqual(summary.postProcessing.destination, .cloud(providerName: "OpenRouter"))
        XCTAssertEqual(
            summary.voiceOutput.destination,
            .cloud(providerName: VoiceOutputProvider.deepgram.displayName)
        )
    }
}
#endif
