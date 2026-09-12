import Foundation
import XCTest

@testable import SpeakApp

final class WhisperKitModelStorageTests: XCTestCase {
    func testDeletingOneModel_reclaimsItsBytesAndPreservesOtherModelsAndExternalLinks() throws {
        let root = try self.makeRoot()
        let storage = WhisperKitModelStorage(root: root)
        let first = try storage.prepare(for: "local/first")
        let second = try storage.prepare(for: "local/second")
        let external = root.deletingLastPathComponent().appendingPathComponent("legacy-cache")
        try Data(repeating: 1, count: 8192).write(to: first.appendingPathComponent("weights"))
        try Data(repeating: 2, count: 4096).write(to: second.appendingPathComponent("weights"))
        try Data("shared cache".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: first.appendingPathComponent("external"),
                                               withDestinationURL: external)

        try storage.removeDownload(for: "local/first")

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try Data(contentsOf: second.appendingPathComponent("weights")).count, 4096)
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "shared cache")
        XCTAssertTrue(try storage.hasOwnership(for: "local/first"), "Keep provenance for a safe retry or reinstall")
        XCTAssertNoThrow(try storage.removeDownload(for: "local/missing"))
        XCTAssertNoThrow(try storage.removeDownload(for: "local/first"))
    }

    func testStoredModelFolder_roundTripsWithoutGuessingHubLayout() throws {
        let root = try self.makeRoot()
        let storage = WhisperKitModelStorage(root: root)
        let base = try storage.prepare(for: "local/model")
        XCTAssertEqual(try storage.prepare(for: "local/model"), base, "An existing owned base must be reusable")
        let actual = base.appendingPathComponent("models/custom/repo/chosen-variant", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try storage.recordModelFolder(actual, for: "local/model")

        let reloaded = WhisperKitModelStorage(root: root)
        XCTAssertEqual(try reloaded.modelFolder(for: "local/model")?.path, actual.path)
        try FileManager.default.removeItem(at: actual)
        XCTAssertNil(try reloaded.modelFolder(for: "local/model"))
    }

    func testUnmarkedDirectory_isNeitherAdoptedNorDeleted() throws {
        let root = try self.makeRoot()
        let storage = WhisperKitModelStorage(root: root)
        let base = try storage.prepare(for: "local/model")
        let ownership = base.deletingLastPathComponent().appendingPathComponent("ownership.json")
        try Data("precious".utf8).write(to: base.appendingPathComponent("weights"))
        try FileManager.default.removeItem(at: ownership)

        XCTAssertThrowsError(try storage.prepare(for: "local/model"))
        XCTAssertThrowsError(try storage.removeDownload(for: "local/model"))
        XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("weights"), encoding: .utf8), "precious")
    }

    func testRootAndDownloadSymlinks_areRejectedBeforeDeletion() throws {
        let root = try self.makeRoot()
        let storage = WhisperKitModelStorage(root: root)
        let base = try storage.prepare(for: "local/model")
        let external = root.deletingLastPathComponent().appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: external.appendingPathComponent("weights"))
        try FileManager.default.removeItem(at: base)
        try FileManager.default.createSymbolicLink(at: base, withDestinationURL: external)
        XCTAssertThrowsError(try storage.removeDownload(for: "local/model"))
        XCTAssertThrowsError(try storage.prepare(for: "local/model"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.appendingPathComponent("weights").path))

        try FileManager.default.removeItem(at: root)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: external)
        XCTAssertThrowsError(try storage.prepare(for: "local/other"))
        XCTAssertThrowsError(try storage.removeDownload(for: "local/model"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.appendingPathComponent("weights").path))
    }

    func testModelFolderRejectsTraversalSiblingPrefixesAndExternalSymlinks() throws {
        let root = try self.makeRoot()
        let storage = WhisperKitModelStorage(root: root)
        let base = try storage.prepare(for: "local/model")
        let sibling = URL(fileURLWithPath: base.path + "-other", isDirectory: true)
        XCTAssertThrowsError(try storage.recordModelFolder(sibling, for: "local/model"))
        XCTAssertThrowsError(
            try storage.recordModelFolder(base.appendingPathComponent("../outside"), for: "local/model")
        )
        let link = base.appendingPathComponent("variant")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try storage.recordModelFolder(link, for: "local/model"))

        let ownership = base.deletingLastPathComponent().appendingPathComponent("ownership.json")
        let forged = ["version": 1, "modelID": "local/model", "modelFolder": "../other"] as [String: Any]
        try JSONSerialization.data(withJSONObject: forged).write(to: ownership)
        XCTAssertThrowsError(try storage.modelFolder(for: "local/model"))
    }

    func testDeletionFailure_keepsOwnershipAndPayloadForRetry() throws {
        let root = try self.makeRoot()
        let storage = WhisperKitModelStorage(root: root)
        let base = try storage.prepare(for: "local/model")
        try Data("keep".utf8).write(to: base.appendingPathComponent("weights"))
        let failing = WhisperKitModelStorage(root: root, removeItem: { _ in throw CocoaError(.fileWriteNoPermission) })

        XCTAssertThrowsError(try failing.removeDownload(for: "local/model"))
        XCTAssertTrue(try storage.hasOwnership(for: "local/model"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appendingPathComponent("weights").path))
        XCTAssertNoThrow(try storage.removeDownload(for: "local/model"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
    }

    func testInitialOwnershipWriteFailure_allowsRetryWithoutAdoptingAnUnmarkedDirectory() throws {
        let root = try self.makeRoot()
        let failing = WhisperKitModelStorage(root: root, writeData: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertThrowsError(try failing.prepare(for: "local/model"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        XCTAssertNoThrow(try WhisperKitModelStorage(root: root).prepare(for: "local/model"))
    }

    private func makeRoot() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.resolvingSymlinksInPath().appendingPathComponent("WhisperKitDownloads", isDirectory: true)
    }
}
