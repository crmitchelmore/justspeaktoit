import Foundation
import XCTest
@testable import SpeakCore

/// Local model identifiers are persisted in settings, profiles, History and
/// install markers. Expected values were captured from the macOS rules that
/// preceded the SpeakCore extraction.
final class LocalModelIdentityTests: XCTestCase {
    private let argmax = WhisperKitHuggingFaceModels.argmaxRepoID

    func testEveryStandardArgmaxAliasResolvesToItsExactVariant() {
        assertAliases(["tiny", "whisper-tiny", "openai_whisper-tiny", " Tiny "], resolveTo: .init(
            modelName: "openai_whisper-tiny", displayName: "Whisper Tiny", approximateSizeMB: 75
        ))
        assertAliases(["base", "whisper-base", "openai_whisper-base"], resolveTo: .init(
            modelName: "openai_whisper-base", displayName: "Whisper Base", approximateSizeMB: 145
        ))
        assertAliases(
            ["small", "whisper-small", "openai_whisper-small", "openai_whisper-small_216mb"],
            resolveTo: .init(
                modelName: "openai_whisper-small_216MB",
                displayName: "Whisper Small",
                approximateSizeMB: 216
            )
        )
    }

    func testEveryLargeV3ArgmaxAliasResolvesToItsExactVariant() {
        assertAliases(
            ["distil-large-v3", "distil-whisper_distil-large-v3", "distil-whisper_distil-large-v3_594mb"],
            resolveTo: .init(
                modelName: "distil-whisper_distil-large-v3_594MB",
                displayName: "Distil-Whisper Large v3",
                approximateSizeMB: 594
            )
        )
        assertAliases(
            [
                "distil-large-v3-turbo", "distil-large-v3_turbo", "distil-whisper_distil-large-v3_turbo",
                "distil-whisper_distil-large-v3_turbo_600mb"
            ],
            resolveTo: .init(
                modelName: "distil-whisper_distil-large-v3_turbo_600MB",
                displayName: "Distil-Whisper Large v3 Turbo",
                approximateSizeMB: 600
            )
        )
        assertAliases(
            [
                "large-v3-turbo", "large-v3_turbo", "openai_whisper-large-v3-v20240930_turbo",
                "openai_whisper-large-v3-v20240930_turbo_632mb"
            ],
            resolveTo: .init(
                modelName: "openai_whisper-large-v3-v20240930_turbo_632MB",
                displayName: "Whisper Large v3 Turbo",
                approximateSizeMB: 632
            )
        )
        assertAliases(
            [
                "openai_whisper-large-v3_turbo", "openai_whisper-large-v3_turbo_954mb",
                "openai-whisper-large-v3-turbo", "OPENAI-WHISPER-LARGE-V3-TURBO-954MB"
            ],
            resolveTo: .init(
                modelName: "openai_whisper-large-v3_turbo_954MB",
                displayName: "Whisper Large v3 Turbo",
                approximateSizeMB: 954
            )
        )
    }

    func testUnknownNamesAreKeptWithAParsedSize() {
        XCTAssertEqual(
            WhisperKitHuggingFaceModels.resolve(repoID: argmax, modelName: "unknown-model_77MB"),
            .init(modelName: "unknown-model_77MB", displayName: "unknown-model_77MB", approximateSizeMB: 77)
        )
        // Shorthands belong to the Argmax repository only.
        XCTAssertEqual(
            WhisperKitHuggingFaceModels.resolve(repoID: "example/custom-whisperkit", modelName: " tiny "),
            .init(modelName: "tiny", displayName: "tiny", approximateSizeMB: 0)
        )
    }

    func testPersistedWhisperKitIdentifiersMigrateAndOthersAreOnlyTrimmed() {
        let prefix = "local/whisperkit/huggingface/argmaxinc/whisperkit-coreml/"
        let expectations: [String: String] = [
            prefix + "openai-whisper-large-v3-turbo": prefix + "openai-whisper-large-v3-turbo-954mb",
            prefix + "tiny": prefix + "openai-whisper-tiny",
            "  \(prefix)large-v3-turbo  ": prefix + "openai-whisper-large-v3-v20240930-turbo-632mb",
            "LOCAL/WHISPERKIT/HUGGINGFACE/argmaxinc/whisperkit-coreml/tiny": prefix + "openai-whisper-tiny",
            "local/whisperkit/huggingface/example/custom/some-model":
                "local/whisperkit/huggingface/example/custom/some-model",
            "local/whisperkit/huggingface/too-short": "local/whisperkit/huggingface/too-short",
            " local/whisperkit/tiny ": "local/whisperkit/tiny",
            "apple/local/SpeechTranscriber": "apple/local/SpeechTranscriber"
        ]
        for (persisted, expected) in expectations {
            XCTAssertEqual(WhisperKitHuggingFaceModels.normalizedModelID(persisted), expected, persisted)
        }
    }

    func testDerivedIdentifiersUseTheSameLossySlug() {
        XCTAssertEqual(LocalModelIdentity.slug("Acme_Models/My.ASR v2 é"), "acme-models/my-asr-v2-é")
        XCTAssertEqual(
            WhisperKitHuggingFaceModels.modelID(repoID: argmax, modelName: "openai_whisper-large-v3_turbo_954MB"),
            "local/whisperkit/huggingface/argmaxinc/whisperkit-coreml/openai-whisper-large-v3-turbo-954mb"
        )
        XCTAssertEqual(
            LocalPostProcessingModel.huggingFaceModelID(
                repoID: "unsloth/Qwen3-0.6B-GGUF",
                filename: "Qwen3-0.6B-Q4_K_M.gguf"
            ),
            "local/post-processing/huggingface/unsloth/qwen3-0-6b-gguf/qwen3-0-6b-q4-k-m-gguf"
        )
        XCTAssertEqual(
            LocalStreamingModelSource(repoID: " acme/models ", modelName: " My_ASR.v2 ").id,
            "local/streaming/huggingface/acme/models/my-asr-v2"
        )
    }

    func testParakeetSourceIdentifierMatchesTheSharedConstant() {
        let source = LocalStreamingModelSource(
            repoID: ParakeetLocalModels.tdtV3Int8RepoID,
            modelName: ParakeetLocalModels.tdtV3Int8ModelName
        )

        XCTAssertEqual(source.id, ParakeetLocalModels.tdtV3Int8SourceID)
        XCTAssertEqual(source.approximateSizeMB, ParakeetLocalModels.tdtV3Int8DownloadSizeMB)
        XCTAssertEqual(source.runtime, LocalStreamingModelSource.sherpaOnnxRuntimeHint)
        XCTAssertEqual(ModelCatalog.localStreamingSources.first?.id, ParakeetLocalModels.tdtV3Int8SourceID)
    }

    func testPostProcessingIdentifiersSeparateDownloadsFromBuiltInRules() {
        XCTAssertTrue(ModelCatalog.postProcessing.contains { $0.id == LocalPostProcessingModel.builtInRulesModelID })
        XCTAssertFalse(LocalPostProcessingModel.isDownloadedModelID(LocalPostProcessingModel.builtInRulesModelID))
        XCTAssertFalse(LocalPostProcessingModel.isDownloadedModelID("LOCAL/POST-PROCESSING/rules"))
        XCTAssertTrue(LocalPostProcessingModel.isDownloadedModelID("local/post-processing/qwen3-0.6b-q4"))
        XCTAssertFalse(LocalPostProcessingModel.isDownloadedModelID("openai/gpt-5-mini"))
    }

    func testGGUFImportMetadataParsesFromTheFilename() {
        let sizes: [String: Int?] = [
            "Qwen3-4B-Q4_K_M.gguf": nil,
            "tiny_model-1.5GB.gguf": 1_536,
            "model 350 MB.gguf": 350,
            "x-2gb-y-100mb.gguf": 2_048,
            "plain.gguf": nil
        ]
        for (filename, expected) in sizes {
            XCTAssertEqual(LocalPostProcessingModel.approximateSizeMB(fromFilename: filename), expected, filename)
        }
        XCTAssertEqual(
            LocalPostProcessingModel.importedDisplayName(
                repoID: "unsloth/Qwen3-4B-GGUF",
                filename: "Qwen3-4B-Q4_K_M.GGUF"
            ),
            "Qwen3 4B Q4 K M from unsloth/Qwen3-4B-GGUF"
        )
        XCTAssertTrue(LocalPostProcessingModel.isGGUFFilename("Model.GGUF"))
        XCTAssertFalse(LocalPostProcessingModel.isGGUFFilename("model.gguf.part"))
    }

    func testStreamingRuntimeTextKeepsItsPersistedStrings() {
        XCTAssertEqual(
            LocalStreamingModelSource.runtimeHint(repoID: "acme/onnx-model", modelName: "m"),
            "sherpa-onnx streaming runtime"
        )
        XCTAssertEqual(
            LocalStreamingModelSource.runtimeHint(repoID: "whisper.cpp-ggml/base", modelName: "m"),
            "whisper.cpp streaming runtime"
        )
        XCTAssertEqual(
            LocalStreamingModelSource.runtimeHint(repoID: "acme/other", modelName: "m"),
            "Streaming ASR runtime"
        )
    }

    private func assertAliases(
        _ aliases: [String],
        resolveTo expected: ResolvedHuggingFaceModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for alias in aliases {
            XCTAssertEqual(
                WhisperKitHuggingFaceModels.resolve(repoID: argmax, modelName: alias),
                expected,
                alias,
                file: file,
                line: line
            )
        }
    }
}
