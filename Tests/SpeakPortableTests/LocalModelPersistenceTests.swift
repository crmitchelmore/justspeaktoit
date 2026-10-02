import Foundation
import XCTest
@testable import SpeakCore

/// Files written by the macOS stores before the SpeakCore extraction must keep
/// loading with the same values, migrate exactly as before and write back the
/// same fields. Fixtures are byte-exact captures, see
/// `LocalModelPersistenceFixtures`.
final class LocalModelPersistenceTests: XCTestCase {
    private static let turboPrefix = "local/whisperkit/huggingface/argmaxinc/whisperkit-coreml/"

    func testImportedTranscriptionRecordsDecodeAndRoundTripFieldForField() throws {
        let data = Data(LocalModelPersistenceFixtures.importedTranscriptionModels.utf8)
        let records = try JSONDecoder().decode([LocalTranscriptionModelRecord].self, from: data)

        XCTAssertEqual(records.map(\.id), [
            Self.turboPrefix + "openai-whisper-tiny",
            "local/whisperkit/huggingface/example/custom-whisperkit/custom-model-123mb",
            Self.turboPrefix + "openai-whisper-large-v3-turbo",
            "local/future-runtime/custom/model"
        ])
        let tiny = records[0]
        XCTAssertEqual(tiny.displayName, "Whisper Tiny from argmaxinc/whisperkit-coreml")
        XCTAssertEqual(tiny.modelName, "openai_whisper-tiny")
        XCTAssertEqual(tiny.engine, "whisperkit")
        XCTAssertEqual(tiny.modelRepo, WhisperKitHuggingFaceModels.argmaxRepoID)
        XCTAssertEqual(tiny.approximateSizeMB, 75)
        XCTAssertFalse(tiny.supportsLiveStreaming)
        XCTAssertNil(records[3].modelRepo)
        XCTAssertTrue(records[3].supportsLiveStreaming)

        // Loading then saving writes the same records with the same fields.
        let saved = try JSONEncoder().encode(records.map { LocalTranscriptionModelRecord(model: $0.model) })
        XCTAssertEqual(try JSONDecoder().decode([LocalTranscriptionModelRecord].self, from: saved), records)
        XCTAssertEqual(try Self.fieldNames(saved), try Self.fieldNames(data))
        XCTAssertFalse(try Self.fieldNames(saved)[3].contains("modelRepo"), "An absent repository stays absent")
    }

    func testImportedTranscriptionRecordsMigrateOnlyStaleAliases() throws {
        let data = Data(LocalModelPersistenceFixtures.importedTranscriptionModels.utf8)
        let records = try JSONDecoder().decode([LocalTranscriptionModelRecord].self, from: data)

        let loaded = records.map { WhisperKitHuggingFaceModels.normalizedImportedModel($0.model) }

        for index in [0, 1, 3] {
            XCTAssertEqual(loaded[index], records[index].model, "Current entries must not trigger a rewrite")
        }
        let migrated = loaded[2]
        XCTAssertEqual(migrated.id, Self.turboPrefix + "openai-whisper-large-v3-turbo-954mb")
        XCTAssertEqual(migrated.displayName, "Whisper Large v3 Turbo from argmaxinc/whisperkit-coreml")
        XCTAssertEqual(migrated.modelName, "openai_whisper-large-v3_turbo_954MB")
        XCTAssertEqual(migrated.approximateSizeMB, 954)
        XCTAssertEqual(migrated.description, "Imported from Hugging Face.")
        XCTAssertEqual(migrated.tags, [.quality])
        XCTAssertEqual(loaded[3].engine, .unknown("future-runtime"))
    }

    func testWhisperKitImportsReproduceThePersistedEntries() throws {
        let data = Data(LocalModelPersistenceFixtures.importedTranscriptionModels.utf8)
        let records = try JSONDecoder().decode([LocalTranscriptionModelRecord].self, from: data)

        XCTAssertEqual(
            WhisperKitHuggingFaceModels.importedModel(
                repoID: WhisperKitHuggingFaceModels.argmaxRepoID,
                modelName: "tiny"
            ),
            records[0].model
        )
        XCTAssertEqual(
            WhisperKitHuggingFaceModels.importedModel(
                repoID: "example/custom-whisperkit",
                modelName: "custom_model_123MB"
            ),
            records[1].model
        )
    }

    func testUnknownEngineSurvivesALoadAndSaveAsTrimmedLowercase() {
        let model = LocalTranscriptionModel(
            id: "local/future/model",
            displayName: "Future",
            modelName: "future",
            engine: LocalTranscriptionEngine(identifier: " Future-Runtime "),
            approximateSizeMB: 1,
            description: "Kept.",
            tags: [.fast]
        )

        let record = LocalTranscriptionModelRecord(model: model)

        XCTAssertEqual(record.engine, "future-runtime")
        XCTAssertEqual(record.model.engine, .unknown("future-runtime"))
        XCTAssertEqual(record.model.tags, [.quality], "Tags are not persisted")
        XCTAssertNil(record.model.backend, "An unknown engine has no executable backend")
    }

    func testStreamingSourcesDecodeRoundTripAndLoadLikeMacOS() throws {
        let data = Data(LocalModelPersistenceFixtures.streamingModelSources.utf8)
        let sources = try JSONDecoder().decode([LocalStreamingModelSource].self, from: data)

        XCTAssertEqual(sources.count, 5)
        XCTAssertEqual(sources[0], ModelCatalog.localStreamingSources[0])
        XCTAssertEqual(sources[0].archiveURL, ParakeetLocalModels.tdtV3Int8ArchiveURL)
        XCTAssertNil(sources[1].archiveURL)
        XCTAssertNil(sources[2].approximateSizeMB)
        XCTAssertEqual(sources[3].runtime, "NeMo / Parakeet runtime")

        let saved = try JSONEncoder().encode(sources)
        XCTAssertEqual(try JSONDecoder().decode([LocalStreamingModelSource].self, from: saved), sources)
        XCTAssertEqual(try Self.fieldNames(saved), try Self.fieldNames(data))

        // macOS keeps runnable sherpa-onnx sources, then re-derives display metadata.
        let loaded = sources
            .filter(LocalStreamingModelSource.isRunnableSherpaOnnxSource)
            .map(LocalStreamingModelSource.normalized)
        XCTAssertEqual(loaded.map(\.id), [sources[0].id, sources[1].id, sources[2].id, sources[4].id])
        XCTAssertEqual(Array(loaded.prefix(3)), Array(sources.prefix(3)), "Current sources are not rewritten")
        XCTAssertEqual(loaded[3].runtime, LocalStreamingModelSource.sherpaOnnxRuntimeHint)
        XCTAssertEqual(loaded[3].approximateSizeMB, 44)
        XCTAssertEqual(loaded.map(\.backend), [LocalModelBackend?](repeating: .sherpaOnnx, count: 4))
        XCTAssertNil(sources[3].backend, "A raw NeMo checkpoint is never executable")
    }

    func testImportedGGUFModelsDecodeAndRoundTripFieldForField() throws {
        let data = Data(LocalModelPersistenceFixtures.importedPostProcessingModels.utf8)
        let models = try JSONDecoder().decode([LocalPostProcessingModel].self, from: data)

        XCTAssertEqual(models, [
            LocalPostProcessingModel.importedModel(
                repoID: "unsloth/Qwen3-4B-GGUF",
                filename: "Qwen3-4B-Q4_K_M.gguf",
                approximateSizeMB: 2_500
            ),
            LocalPostProcessingModel.importedModel(
                repoID: "bartowski/Llama-3.2-1B-Instruct-GGUF",
                filename: "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
                approximateSizeMB: nil
            ),
            LocalPostProcessingModel.importedModel(
                repoID: "example/tiny-models",
                filename: "tiny_model-1.5GB.gguf",
                approximateSizeMB: nil
            )
        ])
        XCTAssertEqual(models[0].id, "local/post-processing/huggingface/unsloth/qwen3-4b-gguf/qwen3-4b-q4-k-m-gguf")
        XCTAssertNil(models[1].approximateSizeMB)
        XCTAssertEqual(models[2].approximateSizeMB, 1_536)

        let saved = try JSONEncoder().encode(models)
        XCTAssertEqual(try JSONDecoder().decode([LocalPostProcessingModel].self, from: saved), models)
        XCTAssertEqual(try Self.fieldNames(saved), try Self.fieldNames(data))
        XCTAssertEqual(models.map(\.backend), [LocalModelBackend?](repeating: .llamaCppGGUF, count: 3))
    }

    /// The field names of each persisted object, in file order.
    private static func fieldNames(_ data: Data) throws -> [Set<String>] {
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return objects.map { Set($0.keys) }
    }
}
