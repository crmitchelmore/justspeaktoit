import Foundation
import SpeakCore
import XCTest
import class WhisperKit.WhisperKit
import class WhisperKit.WhisperKitConfig

@testable import SpeakApp

@MainActor
final class LocalModelStorageLifecycleTests: XCTestCase {
    func testManagedConfiguration_usesAnExclusiveBaseAndTheRecordedSDKFolder() throws {
        let directory = try self.makeDirectory()
        let storage = WhisperKitModelStorage(root: directory.appendingPathComponent("WhisperKitDownloads"))
        let model = try XCTUnwrap(ModelCatalog.localTranscription.first)
        let manager = LocalModelManager(storageDirectory: directory, modelStorage: storage)
        let initial = try manager.configuration(for: model, managedStorage: true)
        let base = try XCTUnwrap(initial.downloadBase)
        XCTAssertEqual(initial.tokenizerFolder, base)
        XCTAssertTrue(initial.download)
        XCTAssertNil(initial.modelFolder)

        let folder = base.appendingPathComponent("actual-sdk-variant", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try storage.recordModelFolder(folder, for: model.id)
        let reloaded = try manager.configuration(for: model, managedStorage: true)
        XCTAssertEqual(reloaded.modelFolder, folder.path)
        XCTAssertEqual(reloaded.downloadBase, base)
        XCTAssertFalse(reloaded.download, "Recorded folders must bypass dependency model discovery")
    }

    func testLegacyRemoval_preservesCacheAndReinstallationSelectsManagedStorage() throws {
        let directory = try self.makeDirectory()
        let model = try XCTUnwrap(ModelCatalog.localTranscription.first)
        let marker = self.marker(for: model, in: directory)
        try Data("installed\n".utf8).write(to: marker)
        let legacyCache = directory.appendingPathComponent("dependency-managed-cache")
        try Data("legacy weights".utf8).write(to: legacyCache)
        let manager = LocalModelManager(storageDirectory: directory)
        XCTAssertEqual(manager.installState(for: model.id), .installed)
        XCTAssertTrue(manager.usesLegacyStorage(model))
        let legacy = try manager.configuration(for: model, managedStorage: false)
        XCTAssertNil(legacy.downloadBase, "Do not guess or relocate an existing dependency cache")

        XCTAssertTrue(manager.delete(model))
        XCTAssertEqual(manager.installState(for: model.id), .notInstalled)
        XCTAssertEqual(try String(contentsOf: legacyCache, encoding: .utf8), "legacy weights")
        XCTAssertNotNil(try manager.configuration(for: model, managedStorage: true).downloadBase)
        XCTAssertEqual(try String(contentsOf: legacyCache, encoding: .utf8), "legacy weights")
    }

    func testDeletionFailure_retainsMarkerAndOffersRetry() throws {
        let directory = try self.makeDirectory()
        let root = directory.appendingPathComponent("WhisperKitDownloads")
        let storage = WhisperKitModelStorage(root: root)
        let model = try XCTUnwrap(ModelCatalog.localTranscription.first)
        let base = try self.installFixture(model, storage: storage, directory: directory)
        let failing = WhisperKitModelStorage(root: root, removeItem: { payload in
            try FileManager.default.removeItem(at: payload.appendingPathComponent("actual-sdk-variant/weights"))
            throw CocoaError(.fileWriteNoPermission)
        })
        let manager = LocalModelManager(storageDirectory: directory, modelStorage: failing)
        XCTAssertEqual(manager.installState(for: model.id), .installed)

        XCTAssertFalse(manager.delete(model))
        manager.refreshInstallStates()
        guard case .failed = manager.installState(for: model.id) else { return XCTFail("Must show deletion failure") }
        XCTAssertTrue(manager.canDelete(model), "The UI must continue to offer deletion recovery")
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.marker(for: model, in: directory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.path))

        let retry = LocalModelManager(storageDirectory: directory, modelStorage: storage)
        XCTAssertTrue(retry.delete(model))
        XCTAssertEqual(retry.installState(for: model.id), .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.marker(for: model, in: directory).path))
        XCTAssertFalse(retry.canDelete(model), "Empty provenance metadata is not another downloaded model")
    }

    func testFailureAfterPayloadRemoval_doesNotReportInstalledOrReuseMissingFolder() throws {
        let directory = try self.makeDirectory()
        let root = directory.appendingPathComponent("WhisperKitDownloads")
        let storage = WhisperKitModelStorage(root: root)
        let model = try XCTUnwrap(ModelCatalog.localTranscription.first)
        let base = try self.installFixture(model, storage: storage, directory: directory)
        var writes = 0
        let failing = WhisperKitModelStorage(root: root, writeData: { data, url in
            writes += 1
            if writes == 2 { throw CocoaError(.fileWriteNoPermission) }
            try data.write(to: url, options: .atomic)
        })
        let manager = LocalModelManager(storageDirectory: directory, modelStorage: failing)

        XCTAssertFalse(manager.delete(model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
        manager.refreshInstallStates()
        guard case .failed = manager.installState(for: model.id) else {
            return XCTFail("Missing payload is not installed")
        }
        XCTAssertTrue(manager.canDelete(model))
        let retry = LocalModelManager(storageDirectory: directory, modelStorage: storage)
        let config = try retry.configuration(for: model, managedStorage: true)
        XCTAssertTrue(config.download)
        XCTAssertNil(config.modelFolder)
        XCTAssertTrue(retry.delete(model))
        XCTAssertEqual(retry.installState(for: model.id), .notInstalled)
    }

    func testMissingManagedDirectory_isNotMistakenForALegacyInstallation() throws {
        let directory = try self.makeDirectory()
        let model = try XCTUnwrap(ModelCatalog.localTranscription.first)
        try Data("installed-managed-v1\n".utf8).write(to: self.marker(for: model, in: directory))
        let manager = LocalModelManager(storageDirectory: directory)
        guard case .failed = manager.installState(for: model.id) else {
            return XCTFail("Missing managed data must fail")
        }
        XCTAssertFalse(manager.usesLegacyStorage(model))
        XCTAssertTrue(manager.delete(model), "An already missing payload should allow marker removal")
        XCTAssertEqual(manager.installState(for: model.id), .notInstalled)
    }

    func testPartialDownloadWithoutInstallMarker_canStillBeRemovedAfterRefresh() throws {
        let directory = try self.makeDirectory()
        let storage = WhisperKitModelStorage(root: directory.appendingPathComponent("WhisperKitDownloads"))
        let model = try XCTUnwrap(ModelCatalog.localTranscription.first)
        let base = try storage.prepare(for: model.id)
        try Data(repeating: 1, count: 4096).write(to: base.appendingPathComponent("partial-download"))
        let manager = LocalModelManager(storageDirectory: directory, modelStorage: storage)
        manager.refreshInstallStates()

        XCTAssertEqual(manager.installState(for: model.id), .notInstalled)
        XCTAssertTrue(manager.canDelete(model), "Partial bytes must remain removable without an installation marker")
        XCTAssertTrue(manager.delete(model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
        XCTAssertFalse(manager.canDelete(model))
    }

    func testFailedManagedUpgrade_doesNotReuseLegacyPipelineOnRetry() async throws {
        let directory = try self.makeDirectory()
        let storage = WhisperKitModelStorage(root: directory.appendingPathComponent("WhisperKitDownloads"))
        let model = try XCTUnwrap(ModelCatalog.localTranscription.first)
        try Data("installed\n".utf8).write(to: self.marker(for: model, in: directory))
        let legacyFolder = directory.appendingPathComponent("legacy-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyFolder, withIntermediateDirectories: false)
        var loads = 0
        let manager = LocalModelManager(storageDirectory: directory, modelStorage: storage, pipelineLoader: { config in
            loads += 1
            if loads == 2 { throw CocoaError(.fileWriteOutOfSpace) }
            let folder: URL
            if let base = config.downloadBase {
                folder = base.appendingPathComponent("managed-variant", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(repeating: 1, count: 4096).write(to: folder.appendingPathComponent("weights"))
            } else {
                folder = legacyFolder
            }
            // Exercise real pipeline identity and modelFolder without downloading or
            // loading Core ML models; these pinned SDK flags leave models unloaded.
            return try await WhisperKit(WhisperKitConfig(modelFolder: folder.path, load: false, download: false))
        })
        let legacy = try await manager.makeReadyPipeline(modelID: model.id)
        XCTAssertEqual(legacy.modelFolder?.path, legacyFolder.path)

        await manager.install(model)
        guard case .failed = manager.installState(for: model.id) else { return XCTFail("Upgrade must fail") }
        XCTAssertTrue(try storage.hasOwnership(for: model.id))
        XCTAssertNil(try storage.modelFolder(for: model.id))
        XCTAssertFalse(manager.isModelLoaded(model.id), "Failed upgrade must retire the cached legacy pipeline")

        await manager.install(model)
        XCTAssertEqual(loads, 3, "Retry must load the managed files instead of accepting the legacy cached instance")
        XCTAssertEqual(manager.installState(for: model.id), .installed)
        let managed = try await manager.makeReadyPipeline(modelID: model.id)
        XCTAssertFalse(managed === legacy)
        XCTAssertEqual(managed.modelFolder, try storage.modelFolder(for: model.id))
        XCTAssertEqual(loads, 3, "A validated managed pipeline remains reusable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFolder.path))
    }

    private func installFixture(
        _ model: LocalTranscriptionModel, storage: WhisperKitModelStorage, directory: URL
    ) throws -> URL {
        let base = try storage.prepare(for: model.id)
        let folder = base.appendingPathComponent("actual-sdk-variant", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data(repeating: 1, count: 4096).write(to: folder.appendingPathComponent("weights"))
        try storage.recordModelFolder(folder, for: model.id)
        try Data("installed-managed-v1\n".utf8).write(to: self.marker(for: model, in: directory))
        return base
    }

    private func marker(for model: LocalTranscriptionModel, in directory: URL) -> URL {
        directory.appendingPathComponent(model.id.replacingOccurrences(of: "/", with: "_") + ".installed")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.resolvingSymlinksInPath()
    }
}

// MARK: - Inference ownership

extension LocalModelStorageLifecycleTests {
    func testDeletion_waitsForEveryActiveInferenceWithoutChangingInstalledState() async throws {
        let firstStarted = self.expectation(description: "First decoder started")
        let secondStarted = self.expectation(description: "Second decoder started")
        var starts = [firstStarted, secondStarted]
        let decoder = SuspendedFileTranscriber(onStart: { starts.removeFirst().fulfill() })
        let fixture = try self.makeInferenceFixture(decoder: decoder)
        let first = Task {
            try await fixture.manager.transcribeFile(at: fixture.audio, modelID: fixture.model.id, language: nil)
        }
        await self.fulfillment(of: [firstStarted], timeout: 2)
        let second = Task {
            try await fixture.manager.transcribeFile(at: fixture.audio, modelID: fixture.model.id, language: nil)
        }
        await self.fulfillment(of: [secondStarted], timeout: 2)

        XCTAssertFalse(fixture.manager.delete(fixture.model))
        XCTAssertFalse(fixture.manager.canDelete(fixture.model))
        XCTAssertEqual(fixture.manager.installState(for: fixture.model.id), .installed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.base.path))
        decoder.completeNext(.success("first result"))
        let firstResult = try await first.value
        XCTAssertFalse(fixture.manager.delete(fixture.model), "One remaining inference still owns the files")

        decoder.completeNext(.success("second result"))
        let secondResult = try await second.value
        XCTAssertEqual(Set([firstResult.text, secondResult.text]), ["first result", "second result"])
        XCTAssertTrue(fixture.manager.delete(fixture.model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.path))
    }

    func testDecoderFailure_releasesInferenceOwnershipForDeletion() async throws {
        let started = self.expectation(description: "Decoder started")
        let decoder = SuspendedFileTranscriber(onStart: { started.fulfill() })
        let fixture = try self.makeInferenceFixture(decoder: decoder)
        let transcription = Task {
            try await fixture.manager.transcribeFile(at: fixture.audio, modelID: fixture.model.id, language: nil)
        }
        await self.fulfillment(of: [started], timeout: 2)
        XCTAssertFalse(fixture.manager.delete(fixture.model))

        decoder.completeNext(.failure(CocoaError(.fileReadCorruptFile)))
        if case .success = await transcription.result { XCTFail("Decoder failure must propagate") }
        XCTAssertTrue(fixture.manager.delete(fixture.model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.path))
    }

    func testCancellation_keepsFilesUntilAnUncooperativeDecoderReturns() async throws {
        let started = self.expectation(description: "Decoder started")
        let decoder = SuspendedFileTranscriber(onStart: { started.fulfill() })
        let fixture = try self.makeInferenceFixture(decoder: decoder)
        let transcription = Task {
            try await fixture.manager.transcribeFile(at: fixture.audio, modelID: fixture.model.id, language: nil)
        }
        await self.fulfillment(of: [started], timeout: 2)

        transcription.cancel()
        XCTAssertFalse(fixture.manager.delete(fixture.model), "Cancellation alone does not end native inference")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.base.path))
        decoder.completeNext(.success("late result"))
        switch await transcription.result {
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        case .success: XCTFail("Cancelled transcription must not publish a late result")
        }
        XCTAssertTrue(fixture.manager.delete(fixture.model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.path))
    }

    func testPipelineFailure_releasesInferenceOwnershipForDeletion() async throws {
        let decoder = SuspendedFileTranscriber(onStart: { XCTFail("Failed loading must not start decoding") })
        let fixture = try self.makeInferenceFixture(decoder: decoder, pipelineLoader: { _ in
            throw CocoaError(.fileReadCorruptFile)
        })
        do {
            _ = try await fixture.manager.transcribeFile(at: fixture.audio, modelID: fixture.model.id, language: nil)
            XCTFail("Pipeline failure must propagate")
        } catch {
            XCTAssertTrue(error is CocoaError)
        }
        XCTAssertTrue(fixture.manager.delete(fixture.model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.path))
    }

    private func makeInferenceFixture(
        decoder: SuspendedFileTranscriber,
        pipelineLoader: @escaping @MainActor (WhisperKitConfig) async throws -> WhisperKit = { config in
            try await WhisperKit(WhisperKitConfig(modelFolder: config.modelFolder, load: false, download: false))
        }
    ) throws -> LocalInferenceFixture {
        let directory = try self.makeDirectory()
        let storage = WhisperKitModelStorage(root: directory.appendingPathComponent("WhisperKitDownloads"))
        let model = try XCTUnwrap(ModelCatalog.localTranscription.first)
        let base = try self.installFixture(model, storage: storage, directory: directory)
        let manager = LocalModelManager(
            storageDirectory: directory, modelStorage: storage,
            pipelineLoader: pipelineLoader,
            fileTranscriber: { _, _ in try await decoder.transcribe() }
        )
        return LocalInferenceFixture(
            manager: manager, model: model, base: base, audio: directory.appendingPathComponent("input.wav")
        )
    }
}

private struct LocalInferenceFixture {
    let manager: LocalModelManager
    let model: LocalTranscriptionModel
    let base: URL
    let audio: URL
}

@MainActor
private final class SuspendedFileTranscriber {
    private let onStart: () -> Void
    private var continuations: [CheckedContinuation<String, Error>] = []

    init(onStart: @escaping () -> Void) { self.onStart = onStart }

    func transcribe() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuations.append(continuation)
            self.onStart()
        }
    }

    func completeNext(_ result: Result<String, Error>) {
        guard !self.continuations.isEmpty else { return XCTFail("No suspended decoder") }
        self.continuations.removeFirst().resume(with: result)
    }
}
