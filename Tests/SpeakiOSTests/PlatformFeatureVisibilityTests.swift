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
        var expectedProviders: Set<String> = ["google", "openai"]
        if AppleLocalModels.supportsSpeechTranscriber || AppleLocalModels.supportsDictationTranscriber {
            expectedProviders.insert("apple")
        }
        XCTAssertEqual(visibleProviders, expectedProviders)
        XCTAssertTrue(
            AppSettings.supportedBatchModels.contains {
                $0.id == OpenAITranscriptionModels.gptTranscribeCatalogID
            }
        )
        XCTAssertTrue(
            AppSettings.openAIBatchModelIDs.contains(OpenAITranscriptionModels.gptTranscribeCatalogID)
        )
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
