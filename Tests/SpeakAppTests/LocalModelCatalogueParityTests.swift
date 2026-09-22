import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// The macOS managers project the shared SpeakCore catalogues and persisted
/// formats; they must not hold a second copy of either.
@MainActor
final class LocalModelCatalogueParityTests: XCTestCase {
    private static let tinyID = "local/whisperkit/huggingface/argmaxinc/whisperkit-coreml/openai-whisper-tiny"
    private static let legacyTurboID =
        "local/whisperkit/huggingface/argmaxinc/whisperkit-coreml/openai-whisper-large-v3-turbo"

    /// `imported-hugging-face-models.json` as written before the extraction:
    /// one current import and one stored before its exact-size alias existed.
    private static let importedModelsFile = [
        #"[{"id":"local\/whisperkit\/huggingface\/argmaxinc\/whisperkit-coreml\/openai-whisper-tiny","#,
        #""displayName":"Whisper Tiny from argmaxinc\/whisperkit-coreml","modelName":"openai_whisper-tiny","#,
        #""engine":"whisperkit","modelRepo":"argmaxinc\/whisperkit-coreml","approximateSizeMB":75,"#,
        #""description":"Imported from Hugging Face.","supportsLiveStreaming":false},"#,
        #"{"id":"local\/whisperkit\/huggingface\/argmaxinc\/whisperkit-coreml\/openai-whisper-large-v3-turbo","#,
        #""displayName":"openai_whisper-large-v3_turbo from argmaxinc\/whisperkit-coreml","#,
        #""modelName":"openai_whisper-large-v3_turbo","engine":"whisperkit","#,
        #""modelRepo":"argmaxinc\/whisperkit-coreml","approximateSizeMB":0,"#,
        #""description":"Imported from Hugging Face.","supportsLiveStreaming":false}]"#
    ].joined()

    /// `streaming-model-sources.json` with the Parakeet source and a raw NeMo
    /// checkpoint that loading drops.
    private static let streamingSourcesFile = [
        #"[{"id":"local\/streaming\/huggingface\/k2-fsa\/sherpa-onnx\/sherpa-onnx-nemo-parakeet-tdt-0-6b-v3-int8","#,
        #""repoID":"k2-fsa\/sherpa-onnx","modelName":"sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8","#,
        #""runtime":"sherpa-onnx streaming runtime","approximateSizeMB":465},"#,
        #"{"id":"local\/streaming\/huggingface\/nvidia\/parakeet-tdt-0-6b-v2\/parakeet-tdt-0-6b-v2","#,
        #""repoID":"nvidia\/parakeet-tdt-0.6b-v2","modelName":"parakeet-tdt-0.6b-v2","#,
        #""runtime":"NeMo \/ Parakeet runtime"}]"#
    ].joined()

    #if !APP_STORE
    func testRecommendedLists_forwardToTheSharedCatalogues() {
        let direct = LocalModelHostSupport.macOS(channel: .direct)
        let streaming = LocalModelManager.recommendedStreamingModelSources
        let postProcessing = LocalPostProcessingModelManager.recommendedModels

        XCTAssertEqual(streaming, ModelCatalog.localStreamingSources)
        XCTAssertEqual(postProcessing, ModelCatalog.localPostProcessing)
        XCTAssertEqual(direct.executableModels(in: ModelCatalog.localStreamingSources), streaming)
        XCTAssertEqual(direct.executableModels(in: ModelCatalog.localPostProcessing), postProcessing)
        XCTAssertTrue(streaming.allSatisfy(LocalModelManager.isSupportedStreamingSource))
    }
    #endif

    func testIdentityForwarders_returnTheSharedResults() {
        XCTAssertEqual(
            LocalModelManager.normalizedLocalModelID(Self.legacyTurboID),
            WhisperKitHuggingFaceModels.normalizedModelID(Self.legacyTurboID)
        )
        XCTAssertEqual(LocalModelManager.slug("My_ASR.v2"), LocalModelIdentity.slug("My_ASR.v2"))
        XCTAssertEqual(
            LocalPostProcessingModelManager.huggingFaceModelID(repoID: "a/b", filename: "C_1.gguf"),
            LocalPostProcessingModel.huggingFaceModelID(repoID: "a/b", filename: "C_1.gguf")
        )
        XCTAssertEqual(
            LocalPostProcessingModelManager.builtInRulesModelID,
            LocalPostProcessingModel.builtInRulesModelID
        )
    }

    /// Reading shared metadata through the forwarders must not build the
    /// manager, whose initialiser creates directories and stats marker files.
    func testSharedMetadata_doesNotConstructTheManager() throws {
        let managersBefore = LocalModelManager.instanceCount

        _ = LocalModelManager.huggingFaceModelID(repoID: WhisperKitHuggingFaceModels.argmaxRepoID, modelName: "tiny")
        _ = LocalModelManager.normalizedLocalModelID(Self.legacyTurboID)
        _ = LocalModelManager.resolveHuggingFaceModel(repoID: "argmaxinc/whisperkit-coreml", modelName: "tiny")
        _ = try JSONDecoder().decode([ImportedModelRecord].self, from: Data(Self.importedModelsFile.utf8))
        _ = LocalPostProcessingModel.importedModel(repoID: "a/b", filename: "c.gguf", approximateSizeMB: nil)
        _ = LocalPostProcessingModelManager.isDownloadedLocalModelID(LocalPostProcessingModel.builtInRulesModelID)
        #if !APP_STORE
        _ = LocalModelManager.recommendedStreamingModelSources.filter(LocalModelManager.isSupportedStreamingSource)
        _ = LocalPostProcessingModelManager.recommendedModels.map(\.option)
        #endif

        XCTAssertEqual(LocalModelManager.instanceCount, managersBefore)
    }

    func testPersistedStores_loadThroughSharedFormatsAndMigrateOnlyStaleEntries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalModelCatalogueParityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let importedURL = directory.appendingPathComponent("imported-hugging-face-models.json")
        try Data(Self.importedModelsFile.utf8).write(to: importedURL)
        #if !APP_STORE
        let streamingURL = directory.appendingPathComponent("streaming-model-sources.json")
        try Data(Self.streamingSourcesFile.utf8).write(to: streamingURL)
        #endif

        let manager = LocalModelManager(storageDirectory: directory)

        let migratedID = Self.legacyTurboID + "-954mb"
        let catalogueCount = ModelCatalog.localTranscription.count
        XCTAssertEqual(Array(manager.availableModels.prefix(catalogueCount)), ModelCatalog.localTranscription)
        XCTAssertEqual(manager.importedModels.map(\.id), [Self.tinyID, migratedID])
        XCTAssertEqual(manager.model(for: Self.legacyTurboID)?.id, migratedID, "Legacy selections still resolve")
        let rewritten = try JSONDecoder().decode([ImportedModelRecord].self, from: Data(contentsOf: importedURL))
        XCTAssertEqual(rewritten.map(\.id), [Self.tinyID, migratedID])
        XCTAssertEqual(rewritten.map(\.model), manager.importedModels)

        let imported = try manager.importHuggingFaceModel(repoID: "example/custom-whisperkit", modelName: "custom_7MB")
        XCTAssertEqual(
            imported,
            WhisperKitHuggingFaceModels.importedModel(repoID: "example/custom-whisperkit", modelName: "custom_7MB")
        )
        let saved = try JSONDecoder().decode([ImportedModelRecord].self, from: Data(contentsOf: importedURL))
        XCTAssertEqual(saved.last, LocalTranscriptionModelRecord(model: imported))
        #if !APP_STORE
        XCTAssertEqual(manager.streamingModelSources.map(\.id), [ParakeetLocalModels.tdtV3Int8SourceID])
        let streamingSaved = try JSONDecoder().decode(
            [LocalStreamingModelSource].self,
            from: Data(contentsOf: streamingURL)
        )
        XCTAssertEqual(streamingSaved, manager.streamingModelSources)
        #endif
    }
}
