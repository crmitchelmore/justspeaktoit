import Foundation
import XCTest
@testable import SpeakCore

/// Portable metadata is not a capability. A host exposes a downloaded model
/// only when it implements both the runtime and the artefact format.
final class LocalModelHostSupportTests: XCTestCase {
    private let transcription = ModelCatalog.localTranscription
    private let streaming = ModelCatalog.localStreamingSources
    private let postProcessing = ModelCatalog.localPostProcessing

    func testMacOSIntelDeveloperIDKeepsExistingRuntimesWithoutPhonon() {
        let direct = LocalModelHostSupport.macOS(channel: .direct, isAppleSilicon: false)

        XCTAssertEqual(direct.backends, [.whisperKitCoreML, .sherpaOnnx, .llamaCppGGUF])
        XCTAssertEqual(direct.executableModels(in: transcription), transcription.filter { $0.engine == .whisperKit })
        XCTAssertFalse(direct.canExecute(model: PhononLocalModels.phonon2))
        XCTAssertEqual(direct.executableModels(in: streaming), streaming)
        XCTAssertEqual(direct.executableModels(in: postProcessing), postProcessing)
    }

    func testMacOSAppleSiliconDeveloperIDAddsActualPhononBackend() {
        let direct = LocalModelHostSupport.macOS(channel: .direct, isAppleSilicon: true)
        XCTAssertEqual(direct.backends, [.whisperKitCoreML, .sherpaOnnx, .llamaCppGGUF, .phononFermion])
        XCTAssertEqual(direct.executableModels(in: transcription), transcription)
        XCTAssertEqual(direct.preferredBackend(for: PhononLocalModels.phonon2), .phononFermion)
        XCTAssertEqual(direct.executableModels(in: streaming), streaming)
        XCTAssertEqual(direct.executableModels(in: postProcessing), postProcessing)
    }

    func testCurrentMacProjectionUsesItsActualArchitecture() {
        #if os(macOS) && arch(arm64)
        let expected = LocalModelHostSupport.macOS(channel: .direct, isAppleSilicon: true)
        #else
        let expected = LocalModelHostSupport.macOS(channel: .direct, isAppleSilicon: false)
        #endif
        XCTAssertEqual(LocalModelHostSupport.macOS(channel: .direct), expected)
    }

    func testMacAppStoreKeepsOnlyInProcessCoreML() {
        let appStore = LocalModelHostSupport.macOS(channel: .appStore)

        XCTAssertEqual(appStore.backends, [.whisperKitCoreML])
        XCTAssertEqual(appStore.executableModels(in: transcription), transcription.filter { $0.engine == .whisperKit })
        for appleSilicon in [false, true] {
            let host = LocalModelHostSupport.macOS(channel: .appStore, isAppleSilicon: appleSilicon)
            XCTAssertEqual(host.backends, [.whisperKitCoreML])
            XCTAssertFalse(host.canExecute(model: PhononLocalModels.phonon2))
            XCTAssertNil(host.preferredBackend(for: PhononLocalModels.phonon2))
        }
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
        for backend in [LocalModelBackend.whisperKitCoreML, .sherpaOnnx, .llamaCppGGUF, .phononFermion] {
            XCTAssertFalse(windows.canExecute(backend))
        }
        for model in windows.executableModels(in: transcription) {
            XCTAssertEqual(windows.preferredBackend(for: model), .whisperCppGGML)
        }
    }

    /// Both desktop hosts run the same whisper.cpp pin, so a newly pinned
    /// catalogue entry appears on Windows and Linux together, with the same
    /// identifiers and order, and neither gains a runtime the other lacks.
    func testLinuxProjectsExactlyTheWindowsWhisperCppEntries() throws {
        let linux = LocalModelHostSupport.linux
        let windows = LocalModelHostSupport.windows

        XCTAssertEqual(linux, windows)
        XCTAssertEqual(linux.executableModels(in: transcription), windows.executableModels(in: transcription))
        XCTAssertEqual(
            Set(linux.executableModels(in: transcription).map(\.id)), Set(WhisperCppModels.all.map(\.catalogueID)),
            "Every pinned GGML entry, and nothing else"
        )
        XCTAssertTrue(linux.executableModels(in: streaming).isEmpty)
        XCTAssertTrue(linux.executableModels(in: postProcessing).isEmpty)
        XCTAssertTrue(linux.executableModels(in: try Self.importedTranscriptionModels()).isEmpty)
        for model in linux.executableModels(in: transcription) {
            XCTAssertEqual(linux.preferredBackend(for: model), .whisperCppGGML)
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
            transcription.filter { $0.engine == .whisperKit }.map(\.backend),
            [LocalModelBackend?](repeating: .whisperKitCoreML,
                                 count: transcription.filter { $0.engine == .whisperKit }.count)
        )
        XCTAssertEqual(PhononLocalModels.phonon2.backend, .phononFermion)
        XCTAssertEqual(PhononLocalModels.phonon2.backends, [.phononFermion])
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
