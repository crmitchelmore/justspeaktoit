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

    func testWindowsExposesOnlyWhisperCppQualifiedCatalogueEntries() throws {
        let windows = LocalModelHostSupport.windows

        XCTAssertEqual(windows.backends, [.whisperCppGGML])
        let qualified = Set(WhisperCppModels.all.map(\.catalogueID))
        XCTAssertEqual(
            windows.executableModels(in: transcription).map(\.id),
            transcription.map(\.id).filter { qualified.contains($0) },
            "Catalogue order, and only entries with pinned GGML weights"
        )
        XCTAssertTrue(windows.executableModels(in: streaming).isEmpty)
        XCTAssertTrue(windows.executableModels(in: postProcessing).isEmpty)
        // Imported Core ML records decode everywhere; they never gain a
        // whisper.cpp route by sharing a name with a catalogue entry.
        XCTAssertTrue(windows.executableModels(in: try Self.importedTranscriptionModels()).isEmpty)
        for backend in [LocalModelBackend.whisperKitCoreML, .sherpaOnnx, .llamaCppGGUF] {
            XCTAssertFalse(windows.canExecute(backend))
        }
        for model in windows.executableModels(in: transcription) {
            XCTAssertEqual(windows.preferredBackend(for: model), .whisperCppGGML)
        }
    }

    func testCoreMLArtifactsNeedTheCoreMLRuntimeWhateverElseAHostRuns() throws {
        // Every non-Apple backend, plus a Core ML loader that is not WhisperKit
        // and WhisperKit reading another format.
        let host = LocalModelHostSupport(backends: [
            .sherpaOnnx,
            .llamaCppGGUF,
            LocalModelBackend(runtime: .whisperKit, artifactFormat: .onnx),
            LocalModelBackend(runtime: .sherpaOnnx, artifactFormat: .coreML)
        ])

        XCTAssertTrue(host.executableModels(in: transcription).isEmpty)
        XCTAssertTrue(host.executableModels(in: try Self.importedTranscriptionModels()).isEmpty)
        XCTAssertEqual(host.executableModels(in: streaming), streaming)
        XCTAssertEqual(host.executableModels(in: postProcessing), postProcessing)
        XCTAssertFalse(host.canExecute(nil))
        // whisper.cpp runs pinned GGML weights, never Core ML artefacts.
        let whisperCpp = LocalModelHostSupport(backends: [.whisperCppGGML])
        XCTAssertTrue(whisperCpp.executableModels(in: try Self.importedTranscriptionModels()).isEmpty)
        XCTAssertFalse(whisperCpp.canExecute(.whisperKitCoreML))
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
