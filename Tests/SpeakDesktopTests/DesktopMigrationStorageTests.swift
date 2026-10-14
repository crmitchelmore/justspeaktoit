import Foundation
import SpeakCore
import SpeakDesktop
import SpeakTestSupport
import XCTest

final class DesktopMigrationStorageTests: XCTestCase {
    private let digests = LocalModelDigestProvider(name: "Staging must fail before hashing") {
        throw DataMigrationError.invalid("Unexpected hashing before private staging.")
    }

    private func root() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private var snapshot: DataMigrationSnapshot {
        .init(manifest: .init(categories: [.settings], scopes: [:]), records: [.settings: []])
    }

    func testDirectorySecurityFailure_AbortsReadAndExportWithoutLeavingStaging() throws {
        let directory = try root()
        let storage = DesktopMigrationArchive.Storage(
            createDirectory: {
                XCTAssertFalse(FileManager.default.fileExists(atPath: $0.path))
                throw DataMigrationError.invalid("Synthetic directory protection failure.")
            },
            createFile: { _ in XCTFail("File creation preceded directory protection.") }
        )
        XCTAssertThrowsError(try DesktopMigrationArchive.read(
            MigrationArchiveFixtures.url("deflate"), digests: digests, stagingRoot: directory, storage: storage
        )) { XCTAssertTrue($0.localizedDescription.contains("Synthetic directory protection failure.")) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        XCTAssertThrowsError(try DesktopMigrationArchive.export(
            snapshot, digests: digests, stagingRoot: directory, storage: storage
        )) { XCTAssertTrue($0.localizedDescription.contains("Synthetic directory protection failure.")) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testPrivateFileFailure_IsFatalRatherThanAValidPartialImport() throws {
        let directory = try root()
        let storage = DesktopMigrationArchive.Storage(
            createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false) },
            createFile: {
                XCTAssertFalse(FileManager.default.fileExists(atPath: $0.path))
                try Data("Synthetic partial creation".utf8).write(to: $0, options: .withoutOverwriting)
                throw DataMigrationError.invalid("Synthetic private file failure.")
            }
        )
        XCTAssertThrowsError(try DesktopMigrationArchive.read(
            MigrationArchiveFixtures.url("deflate"), digests: digests, stagingRoot: directory, storage: storage
        )) { XCTAssertTrue($0.localizedDescription.contains("Synthetic private file failure.")) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        XCTAssertThrowsError(try DesktopMigrationArchive.export(
            snapshot, digests: digests, stagingRoot: directory, storage: storage
        )) { XCTAssertTrue($0.localizedDescription.contains("Synthetic private file failure.")) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testExportProtectsDirectoryAndCreatesEmptyPrivateFileBeforeWriting() throws {
        let directory = try root()
        let events = MigrationStorageEvents()
        let storage = DesktopMigrationArchive.Storage(
            createDirectory: {
                try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false)
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: $0.path).isEmpty)
                events.append("directory")
            },
            createFile: {
                XCTAssertEqual(events.values, ["directory"])
                XCTAssertEqual($0.lastPathComponent, "export.zip")
                try Data().write(to: $0, options: .withoutOverwriting)
                XCTAssertEqual(try Data(contentsOf: $0), Data())
                events.append("file")
            }
        )
        let file = try DesktopMigrationArchive.export(
            snapshot, digests: digests, stagingRoot: directory, storage: storage
        )
        XCTAssertEqual(events.values, ["directory", "file"])
        XCTAssertGreaterThan(try Data(contentsOf: file).count, 0)
    }

    func testCancellationAfterProtection_CreatesNoFileAndRemovesDirectory() async throws {
        let directory = try root()
        let fixture = try MigrationArchiveFixtures.url("deflate")
        let digests = digests
        let snapshot = snapshot
        let storage = DesktopMigrationArchive.Storage(
            createDirectory: {
                try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false)
                withUnsafeCurrentTask { $0?.cancel() }
            },
            createFile: { _ in XCTFail("Cancelled migration created a staging file.") }
        )
        for exporting in [false, true] {
            let task = Task {
                if exporting {
                    _ = try DesktopMigrationArchive.export(
                        snapshot, digests: digests, stagingRoot: directory, storage: storage
                    )
                } else {
                    _ = try DesktopMigrationArchive.read(
                        fixture, digests: digests, stagingRoot: directory, storage: storage
                    )
                }
            }
            do {
                try await task.value
                XCTFail("Cancelled staging succeeded.")
            } catch is CancellationError {
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            }
        }
    }

    func testWindowsWithoutNativePolicy_RefusesReadAndExportBeforeStaging() throws {
        #if os(Windows)
        let directory = try root()
        XCTAssertThrowsError(try DesktopMigrationArchive.read(
            MigrationArchiveFixtures.url("deflate"), digests: digests, stagingRoot: directory
        )) { XCTAssertTrue($0.localizedDescription.contains("native Windows")) }
        XCTAssertThrowsError(try DesktopMigrationArchive.export(snapshot, digests: digests, stagingRoot: directory)) {
            XCTAssertTrue($0.localizedDescription.contains("native Windows"))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        #else
        throw XCTSkip("Requires the native Windows staging boundary.")
        #endif
    }
}

private final class MigrationStorageEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var values: [String] { lock.withLock { events } }
    func append(_ event: String) { lock.withLock { events.append(event) } }
}
