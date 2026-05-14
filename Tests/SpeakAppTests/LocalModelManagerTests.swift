import XCTest

import SpeakCore
@testable import SpeakApp

final class LocalModelManagerTests: XCTestCase {

    func testResolveHuggingFaceModel_mapsTinyAliasToSizedWhisperKitVariant() {
        let resolved = LocalModelManager.resolveHuggingFaceModel(
            repoID: "argmaxinc/whisperkit-coreml",
            modelName: "tiny"
        )

        XCTAssertEqual(resolved.modelName, "openai_whisper-tiny")
        XCTAssertEqual(resolved.displayName, "Whisper Tiny")
        XCTAssertEqual(resolved.approximateSizeMB, 75)
    }

    func testResolveHuggingFaceModel_mapsLargeTurboAliasToExactSizedVariant() {
        let resolved = LocalModelManager.resolveHuggingFaceModel(
            repoID: "argmaxinc/whisperkit-coreml",
            modelName: "openai_whisper-large-v3_turbo"
        )

        XCTAssertEqual(resolved.modelName, "openai_whisper-large-v3_turbo_954MB")
        XCTAssertEqual(resolved.displayName, "Whisper Large v3 Turbo")
        XCTAssertEqual(resolved.approximateSizeMB, 954)
    }

    func testHuggingFaceModelID_usesResolvedModelNameForInstallMarker() {
        let resolved = LocalModelManager.resolveHuggingFaceModel(
            repoID: "argmaxinc/whisperkit-coreml",
            modelName: "openai_whisper-large-v3_turbo"
        )

        XCTAssertEqual(
            LocalModelManager.huggingFaceModelID(
                repoID: "argmaxinc/whisperkit-coreml",
                modelName: resolved.modelName
            ),
            "local/whisperkit/huggingface/argmaxinc/whisperkit-coreml/openai-whisper-large-v3-turbo-954mb"
        )
    }

    func testNormalizedLocalModelID_mapsLegacyLargeTurboAliasToExactSizedVariant() {
        let legacyID = "local/whisperkit/huggingface/argmaxinc/whisperkit-coreml/openai-whisper-large-v3-turbo"

        XCTAssertEqual(
            LocalModelManager.normalizedLocalModelID(legacyID),
            "local/whisperkit/huggingface/argmaxinc/whisperkit-coreml/openai-whisper-large-v3-turbo-954mb"
        )
    }

    func testNormalizedImportedModel_updatesLegacyInstallMarkerID() {
        let legacy = LocalTranscriptionModel(
            id: "local/whisperkit/huggingface/argmaxinc/whisperkit-coreml/openai-whisper-large-v3-turbo",
            displayName: "Whisper Large v3 Turbo from argmaxinc/whisperkit-coreml",
            modelName: "openai_whisper-large-v3_turbo_954MB",
            engine: "whisperkit",
            modelRepo: "argmaxinc/whisperkit-coreml",
            approximateSizeMB: 954,
            description: "Imported from Hugging Face.",
            tags: [.quality]
        )

        let normalized = LocalModelManager.normalizedImportedModel(legacy)

        XCTAssertEqual(
            normalized.id,
            "local/whisperkit/huggingface/argmaxinc/whisperkit-coreml/openai-whisper-large-v3-turbo-954mb"
        )
        XCTAssertEqual(normalized.modelName, "openai_whisper-large-v3_turbo_954MB")
    }

    func testResolveHuggingFaceModel_preservesUnknownRepoModelAndParsesSizeSuffix() {
        let resolved = LocalModelManager.resolveHuggingFaceModel(
            repoID: "example/custom-whisperkit",
            modelName: "custom_model_123MB"
        )

        XCTAssertEqual(resolved.modelName, "custom_model_123MB")
        XCTAssertEqual(resolved.displayName, "custom_model_123MB")
        XCTAssertEqual(resolved.approximateSizeMB, 123)
    }

    func testStreamingRuntimeHint_identifiesSherpaModels() {
        XCTAssertEqual(
            LocalModelManager.streamingRuntimeHint(
                for: "csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26",
                modelName: "streaming-zipformer-en-2023-06-26"
            ),
            "sherpa-onnx streaming runtime"
        )
    }

    func testStreamingApproximateSizeMB_identifiesKnownSherpaModels() {
        XCTAssertEqual(
            LocalModelManager.streamingApproximateSizeMB(
                repoID: "csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06",
                modelName: "streaming-zipformer-en-kroko-2025-08-06"
            ),
            71
        )
        XCTAssertEqual(
            LocalModelManager.streamingApproximateSizeMB(
                repoID: "csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17",
                modelName: "streaming-zipformer-en-20M-2023-02-17"
            ),
            44
        )
    }

    @MainActor
    func testRecommendedStreamingSources_includeSelectableSherpaCandidate() {
        let sources = LocalModelManager.recommendedStreamingModelSources
        let hasSherpa = sources.contains {
            $0.repoID == "csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06"
                && $0.modelName == "streaming-zipformer-en-kroko-2025-08-06"
                && $0.runtime == "sherpa-onnx streaming runtime"
        }
        XCTAssertTrue(hasSherpa)
    }

    func testSupportedStreamingSource_rejectsStaleParakeetSource() {
        let source = LocalStreamingModelSource(
            repoID: "nvidia/parakeet-tdt-0.6b-v2",
            modelName: "parakeet-tdt-0.6b-v2",
            runtime: "NeMo / Parakeet runtime"
        )

        XCTAssertFalse(LocalModelManager.isSupportedStreamingSource(source))
    }

    @MainActor
    func testRecommendedStreamingSources_onlyIncludeDownloadableZipformerModels() {
        let sources = LocalModelManager.recommendedStreamingModelSources

        XCTAssertFalse(sources.contains { $0.repoID == "k2-fsa/sherpa-onnx" })
        XCTAssertTrue(sources.allSatisfy(LocalModelManager.isSupportedStreamingSource))
        XCTAssertTrue(sources.allSatisfy { ($0.approximateSizeMB ?? 0) > 0 })
    }

    @MainActor
    func testRecommendedLocalPostProcessingModels_includeHuggingFaceGGUFModelsWithSizes() {
        let models = LocalPostProcessingModelManager.recommendedModels

        XCTAssertTrue(models.contains { $0.repoID == "bartowski/Qwen2.5-1.5B-Instruct-GGUF" })
        XCTAssertTrue(models.allSatisfy { $0.filename.lowercased().hasSuffix(".gguf") })
        XCTAssertTrue(models.allSatisfy { ($0.approximateSizeMB ?? 0) > 0 })
    }

    func testLocalPostProcessingModelID_identifiesDownloadedModels() {
        XCTAssertTrue(
            LocalPostProcessingModelManager.isDownloadedLocalModelID(
                "local/post-processing/qwen2.5-0.5b-instruct-q4"
            )
        )
        XCTAssertFalse(
            LocalPostProcessingModelManager.isDownloadedLocalModelID(
                LocalPostProcessingModelManager.builtInRulesModelID
            )
        )
    }

    func testLocalPostProcessingPrompt_keepsTranscriptSeparateFromSystemInstructions() {
        let systemPrompt = LocalPostProcessingModelManager.localSystemPrompt("Always output in bullet points.")
        let userPrompt = LocalPostProcessingModelManager.localUserPrompt(
            systemPrompt: "Always output in bullet points.",
            rawText: "hello world"
        )

        XCTAssertTrue(systemPrompt.contains("<instructions>"))
        XCTAssertTrue(systemPrompt.contains("Always output in bullet points."))
        XCTAssertFalse(userPrompt.contains("Always output in bullet points."))
        XCTAssertTrue(userPrompt.contains("<raw_transcript>"))
        XCTAssertTrue(userPrompt.contains("hello world"))
    }
}
