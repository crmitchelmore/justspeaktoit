import XCTest
@testable import SpeakCore

/// The iOS projection of the downloaded-model catalogue (issue #1650) and the
/// shared helpers the iOS and macOS WhisperKit hosts both use.
final class IOSLocalTranscriptionCatalogueTests: XCTestCase {
    func testIOSProjection_listsEveryWhisperKitCatalogueEntryAndNothingElse() {
        let whisperKit = ModelCatalog.localTranscription.filter { $0.engine == .whisperKit }
        XCTAssertFalse(whisperKit.isEmpty)
        XCTAssertEqual(ModelCatalog.iOSLocalTranscription, whisperKit)
        XCTAssertTrue(ModelCatalog.iOSLocalTranscription.allSatisfy { $0.id.hasPrefix("local/") })
    }

    func testIOSHostSupport_rejectsRuntimesThatWouldNeedDownloadedOrUnbundledCode() {
        let support = LocalModelHostSupport.iOS
        XCTAssertEqual(support.backends, [.whisperKitCoreML])
        let others = ModelCatalog.localTranscription.filter { $0.engine != .whisperKit }
        XCTAssertFalse(others.isEmpty, "Phonon and other non-WhisperKit entries keep this assertion meaningful")
        XCTAssertTrue(support.executableModels(in: others).isEmpty)
        XCTAssertTrue(support.executableModels(in: ModelCatalog.localPostProcessing).isEmpty)
        XCTAssertTrue(support.executableModels(in: ModelCatalog.localStreamingSources).isEmpty)
    }

    func testIOSHostSupport_admitsHuggingFaceWhisperKitImports() {
        let imported = WhisperKitHuggingFaceModels.importedModel(repoID: "owner/repo", modelName: "custom_variant")
        XCTAssertEqual(LocalModelHostSupport.iOS.executableModels(in: [imported]), [imported])
    }

    func testRepoInput_requiresOwnerAndName() {
        XCTAssertTrue(HuggingFaceRepoInput.isValidRepoID("argmaxinc/whisperkit-coreml"))
        XCTAssertFalse(HuggingFaceRepoInput.isValidRepoID("whisperkit-coreml"))
        XCTAssertFalse(HuggingFaceRepoInput.isValidRepoID("a/b/c"))
        XCTAssertFalse(HuggingFaceRepoInput.isValidRepoID(""))
    }

    func testCleanedWhisperTranscript_silenceIsEmpty() {
        XCTAssertEqual(TranscriptPostProcessingPolicy.cleanedWhisperTranscript(" [BLANK_AUDIO] "), "")
        XCTAssertEqual(TranscriptPostProcessingPolicy.cleanedWhisperTranscript("[blank_audio][BLANK_AUDIO]"), "")
        XCTAssertEqual(TranscriptPostProcessingPolicy.cleanedWhisperTranscript("   \n "), "")
    }

    func testCleanedWhisperTranscript_keepsSpeechAndCollapsesWhitespace() {
        XCTAssertEqual(
            TranscriptPostProcessingPolicy.cleanedWhisperTranscript(" Hello  [BLANK_AUDIO]\n world "),
            "Hello world"
        )
    }

    func testLoadImportedModels_dedupesKeepingTheLaterImport() {
        let first = WhisperKitHuggingFaceModels.importedModel(repoID: "owner/repo", modelName: "variant")
        let second = WhisperKitHuggingFaceModels.importedModel(repoID: "owner/repo", modelName: "variant")
        let other = WhisperKitHuggingFaceModels.importedModel(repoID: "owner/repo", modelName: "other")
        let records = [first, other, second].map(LocalTranscriptionModelRecord.init(model:))

        let (models, didMigrate) = WhisperKitHuggingFaceModels.loadImportedModels(from: records)

        XCTAssertFalse(didMigrate)
        XCTAssertEqual(models.map(\.id), [other.id, second.id])
    }
}
