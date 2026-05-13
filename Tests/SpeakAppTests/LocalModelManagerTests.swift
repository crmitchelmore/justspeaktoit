import XCTest

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

    func testResolveHuggingFaceModel_preservesUnknownRepoModelAndParsesSizeSuffix() {
        let resolved = LocalModelManager.resolveHuggingFaceModel(
            repoID: "example/custom-whisperkit",
            modelName: "custom_model_123MB"
        )

        XCTAssertEqual(resolved.modelName, "custom_model_123MB")
        XCTAssertEqual(resolved.displayName, "custom_model_123MB")
        XCTAssertEqual(resolved.approximateSizeMB, 123)
    }

    func testStreamingRuntimeHint_identifiesParakeetModels() {
        XCTAssertEqual(
            LocalModelManager.streamingRuntimeHint(
                for: "nvidia/parakeet-tdt-0.6b-v2",
                modelName: "parakeet-tdt-0.6b-v2"
            ),
            "NeMo / Parakeet streaming runtime"
        )
    }
}
