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
