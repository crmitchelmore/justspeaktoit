import XCTest

@testable import SpeakCore

/// Selection, availability, and routing behaviour for Apple's local speech
/// engines (legacy SFSpeechRecognizer, SpeechTranscriber, DictationTranscriber).
///
/// The SpeechAnalyzer APIs themselves only exist on OS 26+, so anything that
/// touches them is gated with `#available`/`XCTSkip` and the rest asserts on
/// runtime availability flags — the suite passes on any CI runner OS.
final class AppleLocalModelsTests: XCTestCase {

    func testPreferredSpeechModelID_prefersAnalyzerEnginesInOrder() {
        XCTAssertEqual(
            AppleLocalModels.preferredSpeechModelID(
                speechTranscriberAvailable: true, dictationTranscriberAvailable: true
            ),
            AppleLocalModels.speechTranscriberModelID
        )
        XCTAssertEqual(
            AppleLocalModels.preferredSpeechModelID(
                speechTranscriberAvailable: false, dictationTranscriberAvailable: true
            ),
            AppleLocalModels.dictationTranscriberModelID
        )
        XCTAssertEqual(
            AppleLocalModels.preferredSpeechModelID(
                speechTranscriberAvailable: false, dictationTranscriberAvailable: false
            ),
            AppleLocalModels.legacySpeechModelID
        )
    }

    func testPreferredSpeechModelID_oneArgumentAPIKeepsLegacySelectionBehaviour() {
        XCTAssertEqual(
            AppleLocalModels.preferredSpeechModelID(speechTranscriberAvailable: true),
            AppleLocalModels.speechTranscriberModelID
        )
        XCTAssertEqual(
            AppleLocalModels.preferredSpeechModelID(speechTranscriberAvailable: false),
            AppleLocalModels.legacySpeechModelID
        )
    }

    func testModelClassification_coversAnalyzerEngines() {
        XCTAssertTrue(AppleLocalModels.isSpeechAnalyzerModel(AppleLocalModels.speechTranscriberModelID))
        XCTAssertTrue(AppleLocalModels.isSpeechAnalyzerModel(AppleLocalModels.dictationTranscriberModelID))
        XCTAssertFalse(AppleLocalModels.isSpeechAnalyzerModel(AppleLocalModels.legacySpeechModelID))
        XCTAssertFalse(AppleLocalModels.isSpeechAnalyzerModel("apple/local/Dictation"))

        XCTAssertTrue(AppleLocalModels.isAppleSpeechModel(AppleLocalModels.dictationTranscriberModelID))
        XCTAssertTrue(AppleLocalModels.isAppleSpeechModel(AppleLocalModels.legacySpeechModelID))
    }

    func testDictationAvailability_tracksOSVersion() {
        if #available(macOS 26.0, iOS 26.0, *) {
            XCTAssertTrue(AppleLocalModels.supportsDictationTranscriber)
        } else {
            XCTAssertFalse(AppleLocalModels.supportsDictationTranscriber)
            XCTAssertFalse(AppleLocalModels.supportsSpeechTranscriber)
        }
    }

    func testAnalyzerEngine_mapsModelIDsBothWays() throws {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw XCTSkip("SpeechAnalyzer engines require OS 26")
        }
        XCTAssertEqual(
            AppleSpeechAnalyzerEngine(modelID: AppleLocalModels.speechTranscriberModelID),
            .speechTranscriber
        )
        XCTAssertEqual(
            AppleSpeechAnalyzerEngine(modelID: AppleLocalModels.dictationTranscriberModelID),
            .dictationTranscriber
        )
        // Unknown ids default to the flagship module.
        XCTAssertEqual(AppleSpeechAnalyzerEngine(modelID: "other/model"), .speechTranscriber)
        XCTAssertEqual(
            AppleSpeechAnalyzerEngine.speechTranscriber.modelID,
            AppleLocalModels.speechTranscriberModelID
        )
        XCTAssertEqual(
            AppleSpeechAnalyzerEngine.dictationTranscriber.modelID,
            AppleLocalModels.dictationTranscriberModelID
        )
    }

    func testNormalizedLiveModel_mapsAnalyzerModelsToBestAvailable() {
        XCTAssertEqual(
            ModelCatalog.normalizedLiveTranscriptionModel(AppleLocalModels.dictationTranscriberModelID),
            AppleLocalModels.preferredSpeechModelID
        )
        XCTAssertEqual(
            ModelCatalog.normalizedLiveTranscriptionModel(AppleLocalModels.speechTranscriberModelID),
            AppleLocalModels.preferredSpeechModelID
        )
    }

    func testNormalizedBatchModel_fallsBackThroughAnalyzerEngines() {
        let speech = ModelCatalog.normalizedBatchTranscriptionModel(
            AppleLocalModels.speechTranscriberModelID
        )
        if AppleLocalModels.supportsSpeechTranscriber {
            XCTAssertEqual(speech, AppleLocalModels.speechTranscriberModelID)
        } else if AppleLocalModels.supportsDictationTranscriber {
            XCTAssertEqual(speech, AppleLocalModels.dictationTranscriberModelID)
        } else {
            XCTAssertEqual(speech, ModelCatalog.defaultBatchTranscriptionModel)
        }

        let dictation = ModelCatalog.normalizedBatchTranscriptionModel(
            AppleLocalModels.dictationTranscriberModelID
        )
        if AppleLocalModels.supportsDictationTranscriber {
            XCTAssertEqual(dictation, AppleLocalModels.dictationTranscriberModelID)
        } else {
            XCTAssertEqual(dictation, ModelCatalog.defaultBatchTranscriptionModel)
        }
    }

    // MARK: - Asset install wait policy

    func testAssetWait_installedStopsImmediately() {
        XCTAssertEqual(
            AppleSpeechAssetWaitPolicy.step(
                status: .installed, didRequestInstall: true, consecutiveSupportedPolls: 0
            ),
            .installed
        )
    }

    func testAssetWait_supportedWithoutInstallRequestFailsFast() {
        // Nothing was queued for download, so `.supported` will never advance:
        // waiting out the 30s budget just delays an inevitable failure.
        XCTAssertEqual(
            AppleSpeechAssetWaitPolicy.step(
                status: .supported, didRequestInstall: false, consecutiveSupportedPolls: 1
            ),
            .giveUp
        )
    }

    func testAssetWait_supportedAfterInstallRequestGetsShortGraceOnly() {
        // `.supported` is transient right after `downloadAndInstall()` returns,
        // so it is tolerated briefly and then abandoned.
        XCTAssertEqual(
            AppleSpeechAssetWaitPolicy.step(
                status: .supported, didRequestInstall: true, consecutiveSupportedPolls: 1
            ),
            .keepWaiting
        )
        XCTAssertEqual(
            AppleSpeechAssetWaitPolicy.step(
                status: .supported,
                didRequestInstall: true,
                consecutiveSupportedPolls: AppleSpeechAssetWaitPolicy.supportedGracePolls
            ),
            .keepWaiting
        )
        XCTAssertEqual(
            AppleSpeechAssetWaitPolicy.step(
                status: .supported,
                didRequestInstall: true,
                consecutiveSupportedPolls: AppleSpeechAssetWaitPolicy.supportedGracePolls + 1
            ),
            .giveUp
        )
        XCTAssertLessThan(
            AppleSpeechAssetWaitPolicy.supportedGracePolls,
            AppleSpeechAssetWaitPolicy.maxPolls
        )
    }

    func testAssetWait_downloadingKeepsFullBudget() {
        XCTAssertEqual(
            AppleSpeechAssetWaitPolicy.step(
                status: .downloading,
                didRequestInstall: false,
                consecutiveSupportedPolls: AppleSpeechAssetWaitPolicy.maxPolls
            ),
            .keepWaiting
        )
    }

    func testAssetWait_unsupportedGivesUp() {
        XCTAssertEqual(
            AppleSpeechAssetWaitPolicy.step(
                status: .unsupported, didRequestInstall: true, consecutiveSupportedPolls: 0
            ),
            .giveUp
        )
    }

    func testDictationTranscriberModel_routesToAppleOnDevice() {
        XCTAssertEqual(
            ModelRouting.family(for: AppleLocalModels.dictationTranscriberModelID),
            .appleSpeech
        )
        let route = LiveTranscriptionRouting.route(
            for: AppleLocalModels.dictationTranscriberModelID
        )
        XCTAssertEqual(route?.provider, .apple)
        XCTAssertNil(route?.apiKeyIdentifier)
        XCTAssertEqual(route?.apiModelName, AppleLocalModels.dictationTranscriberModelID)
    }
}
