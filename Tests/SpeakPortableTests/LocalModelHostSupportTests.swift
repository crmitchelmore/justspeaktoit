import Foundation
import XCTest
@testable import SpeakCore

/// Portable metadata is not a capability. A host exposes a downloaded model
/// only when it implements both the runtime and the artefact format.
final class LocalModelHostSupportTests: XCTestCase {
    private let transcription = ModelCatalog.localTranscription
    private let streaming = ModelCatalog.localStreamingSources
    private let postProcessing = ModelCatalog.localPostProcessing

    func testMacOSDeveloperIDExecutesEveryCatalogueEntry() {
        let direct = LocalModelHostSupport.macOS(channel: .direct)

        XCTAssertEqual(direct.backends, [.whisperKitCoreML, .sherpaOnnx, .llamaCppGGUF])
        XCTAssertEqual(direct.executableModels(in: transcription), transcription)
        XCTAssertEqual(direct.executableModels(in: streaming), streaming)
        XCTAssertEqual(direct.executableModels(in: postProcessing), postProcessing)
    }

    func testMacAppStoreKeepsOnlyInProcessCoreML() {
        let appStore = LocalModelHostSupport.macOS(channel: .appStore)

        XCTAssertEqual(appStore.backends, [.whisperKitCoreML])
        XCTAssertEqual(appStore.executableModels(in: transcription), transcription)
        XCTAssertTrue(appStore.executableModels(in: streaming).isEmpty)
        XCTAssertTrue(appStore.executableModels(in: postProcessing).isEmpty)
    }

    func testWindowsExposesNoDownloadedModelAsAnExecutableRoute() throws {
        let windows = LocalModelHostSupport.windows

        XCTAssertEqual(windows, .unsupported)
        XCTAssertTrue(windows.executableModels(in: transcription).isEmpty)
        XCTAssertTrue(windows.executableModels(in: streaming).isEmpty)
        XCTAssertTrue(windows.executableModels(in: postProcessing).isEmpty)
        // Records that decode on every platform are not capabilities either.
        XCTAssertTrue(windows.executableModels(in: try Self.importedTranscriptionModels()).isEmpty)
        for backend in [LocalModelBackend.whisperKitCoreML, .sherpaOnnx, .llamaCppGGUF] {
            XCTAssertFalse(windows.canExecute(backend))
        }
    }

    func testCoreMLArtifactsNeedTheCoreMLRuntimeWhateverElseAHostRuns() throws {
        // Every non-Apple backend, plus the Whisper runtime without Core ML
        // artefacts and a Core ML loader that is not WhisperKit.
        let whisperCpp = LocalModelRuntime(rawValue: "whisper.cpp")
        let host = LocalModelHostSupport(backends: [
            .sherpaOnnx,
            .llamaCppGGUF,
            LocalModelBackend(runtime: whisperCpp, artifactFormat: LocalModelArtifactFormat(rawValue: "ggml")),
            LocalModelBackend(runtime: .whisperKit, artifactFormat: .onnx),
            LocalModelBackend(runtime: .sherpaOnnx, artifactFormat: .coreML)
        ])

        XCTAssertTrue(host.executableModels(in: transcription).isEmpty)
        XCTAssertTrue(host.executableModels(in: try Self.importedTranscriptionModels()).isEmpty)
        XCTAssertEqual(host.executableModels(in: streaming), streaming)
        XCTAssertEqual(host.executableModels(in: postProcessing), postProcessing)
        XCTAssertFalse(host.canExecute(nil))
    }

    func testBackendsDeriveFromAdmissionRulesNotCatalogueMembershipOrPrefixes() {
        XCTAssertEqual(
            transcription.map(\.backend),
            [LocalModelBackend?](repeating: .whisperKitCoreML, count: transcription.count)
        )
        let staleRuntimeText = LocalStreamingModelSource(
            repoID: "csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26",
            modelName: "streaming-zipformer-en-2023-06-26",
            runtime: LocalStreamingModelSource.genericRuntimeHint
        )
        XCTAssertEqual(staleRuntimeText.backend, .sherpaOnnx)
        let rawNeMo = LocalStreamingModelSource(
            repoID: "nvidia/parakeet-tdt-0.6b-v2",
            modelName: "parakeet-tdt-0.6b-v2",
            runtime: LocalStreamingModelSource.sherpaOnnxRuntimeHint
        )
        XCTAssertNil(rawNeMo.backend, "A raw NeMo checkpoint is not executable whatever its runtime text says")
        let notGGUF = LocalPostProcessingModel(
            displayName: "Weights",
            repoID: "example/weights",
            filename: "model.safetensors",
            approximateSizeMB: nil,
            description: ""
        )
        XCTAssertNil(notGGUF.backend)
        let prefixOnly = LocalTranscriptionModel(
            id: "local/whisperkit/looks-executable",
            displayName: "Prefix only",
            modelName: "prefix-only",
            engine: .transcribeCpp,
            approximateSizeMB: 1,
            description: "",
            tags: []
        )
        XCTAssertNil(prefixOnly.backend, "An identifier prefix does not select a runtime")
    }

    private static func importedTranscriptionModels() throws -> [LocalTranscriptionModel] {
        try JSONDecoder().decode(
            [LocalTranscriptionModelRecord].self,
            from: Data(LocalModelPersistenceFixtures.importedTranscriptionModels.utf8)
        ).map(\.model)
    }
}
