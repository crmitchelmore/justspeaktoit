import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class LocalModelStorageFilesTests: XCTestCase {
    func testSourceFile_isNilUntilSavedThenRoundTrips() throws {
        let file = LocalModelSourceFile<String>(url: try self.makeDirectory().appendingPathComponent("list.json"))
        XCTAssertNil(try file.load())

        try file.save(["a", "b"])
        XCTAssertEqual(try file.load(), ["a", "b"])
    }

    func testRepoInput_requiresExactlyOwnerAndRepo() {
        XCTAssertTrue(HuggingFaceRepoInput.isValidRepoID("argmaxinc/whisperkit-coreml"))
        XCTAssertFalse(HuggingFaceRepoInput.isValidRepoID("whisperkit-coreml"))
        XCTAssertFalse(HuggingFaceRepoInput.isValidRepoID("a/b/c"))
    }

    func testStagedInstall_replacesOnlyAfterTheFillSucceeds() async throws {
        let final = try self.makeDirectory().appendingPathComponent("models/model.gguf")
        try await StagedModelInstall.install(at: final) { try Data("v1".utf8).write(to: $0) }
        XCTAssertEqual(try String(contentsOf: final, encoding: .utf8), "v1")

        var staging: URL?
        do {
            try await StagedModelInstall.install(at: final) { url in
                staging = url
                try Data("partial".utf8).write(to: url)
                throw CocoaError(.fileWriteUnknown)
            }
            XCTFail("A failed fill must throw")
        } catch {}
        XCTAssertEqual(try String(contentsOf: final, encoding: .utf8), "v1", "A failed fill keeps the old model")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(staging).path))

        try await StagedModelInstall.install(at: final) { try Data("v2".utf8).write(to: $0) }
        XCTAssertEqual(try String(contentsOf: final, encoding: .utf8), "v2")
    }

    func testImportedModels_keepTheLatestImportOfEachIdentifier() throws {
        let store = LocalTranscriptionSourceStore(directory: try self.makeDirectory())
        let first = WhisperKitHuggingFaceModels.importedModel(repoID: "owner/one", modelName: "openai_whisper-tiny")
        let second = WhisperKitHuggingFaceModels.importedModel(repoID: "owner/two", modelName: "openai_whisper-base")
        try store.saveImportedModels([first, second, first])

        XCTAssertEqual(try store.loadImportedModels().map(\.id), [second.id, first.id])
    }

    #if !APP_STORE
    func testStreamingSourceInput_rejectsSourcesTheRuntimeCannotRun() throws {
        let source = try LocalTranscriptionSourceStore.streamingSource(
            repoID: " csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26 ",
            modelName: "sherpa-onnx-streaming-zipformer-en-2023-06-26"
        )
        XCTAssertEqual(source.repoID, "csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26")
        XCTAssertThrowsError(
            try LocalTranscriptionSourceStore.streamingSource(repoID: "nvidia/parakeet-tdt-0.6b-v3", modelName: "x")
        )
        XCTAssertThrowsError(try LocalTranscriptionSourceStore.streamingSource(repoID: "nvidia", modelName: "x"))
    }

    func testStreamingSources_dropUnrunnableEntriesAndRewriteTheFile() throws {
        let directory = try self.makeDirectory()
        let store = LocalTranscriptionSourceStore(directory: directory)
        let runnable = LocalStreamingModelSource(
            repoID: "csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26",
            modelName: "sherpa-onnx-streaming-zipformer-en-2023-06-26"
        )
        let checkpoint = LocalStreamingModelSource(repoID: "nvidia/parakeet-tdt-0.6b-v3", modelName: "parakeet")
        try store.saveStreamingSources([runnable, checkpoint])

        let loaded = try store.loadStreamingSources()
        XCTAssertEqual(loaded.map(\.id), [runnable.id])
        let file = LocalModelSourceFile<LocalStreamingModelSource>(
            url: directory.appendingPathComponent("streaming-model-sources.json")
        )
        XCTAssertEqual(try file.load(), loaded, "A migrated list must be written back")
    }

    #endif

    func testInstallMarkers_deriveStateFromMarkerAndManagedFolder() throws {
        let directory = try self.makeDirectory()
        let storage = WhisperKitModelStorage(root: directory.appendingPathComponent("WhisperKitDownloads"))
        let markers = WhisperKitInstallMarkers(directory: directory, fileManager: .default, modelStorage: storage)
        let model = try XCTUnwrap(ModelCatalog.localTranscription.first)
        XCTAssertEqual(markers.installState(for: model), .notInstalled)

        try markers.recordManagedInstall(for: model)
        guard case .failed = markers.installState(for: model) else {
            return XCTFail("A managed marker without its recorded folder is not an install")
        }
        XCTAssertFalse(markers.usesLegacyStorage(model))

        try Data("installed\n".utf8).write(to: markers.url(for: model))
        XCTAssertEqual(markers.installState(for: model), .installed)
        XCTAssertTrue(markers.usesLegacyStorage(model))

        try markers.remove(for: model)
        XCTAssertFalse(markers.exists(for: model))
    }

    #if !APP_STORE
    func testLlamaCppInstallError_explainsKnownFailures() {
        struct Failure: LocalizedError {
            let errorDescription: String?
        }
        XCTAssertTrue(
            LlamaCppRuntime.readableInstallError(from: Failure(errorDescription: "No matching distribution found"))
                .contains("Python 3.11 or 3.12")
        )
        XCTAssertTrue(
            LlamaCppRuntime.readableInstallError(from: Failure(errorDescription: "CMake Error at line 1"))
                .contains("Xcode Command Line Tools")
        )
        XCTAssertEqual(
            LlamaCppRuntime.readableInstallError(from: Failure(errorDescription: String(repeating: "x", count: 600)))
                .count,
            500
        )
    }

    #endif

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalModelStorageFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
