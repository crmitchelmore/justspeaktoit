import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakDesktop

final class DesktopMigrationArchiveExportTests: XCTestCase {
    private let digests = LocalModelDigestProvider(name: "Independent audio fixture vector") { ExportFixtureHasher() }

    private func root() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func snapshot(_ directory: URL) throws -> DataMigrationSnapshot {
        try MigrationTestArchive.read(MigrationArchiveFixtures.url("deflate"), digests: digests,
                                         stagingRoot: directory)
    }

    func testCanonicalZIP64Export_RoundTripsEveryRecordAndStreamedAudio() throws {
        let directory = try root()
        let source = try snapshot(directory)
        let file = try MigrationTestArchive.export(source, digests: digests, stagingRoot: directory)
        let result = try MigrationTestArchive.read(file, digests: digests, stagingRoot: directory)
        XCTAssertEqual(result.records, source.records)
        XCTAssertEqual(result.manifest.categories, source.manifest.categories)
        XCTAssertEqual(result.manifest.createdAt, source.manifest.createdAt)
        XCTAssertEqual(result.manifest.scopes, source.manifest.scopes)
        XCTAssertTrue(result.notices.isEmpty)
        XCTAssertEqual(Set(result.files.keys), Set(source.files.keys))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.files["recordings/test.wav"])),
                       MigrationArchiveFixtures.audio)
        XCTAssertEqual(file.lastPathComponent, "export.zip")
        XCTAssertTrue(file.deletingLastPathComponent().lastPathComponent.hasPrefix("migration-export-"))
    }

    func testStoredExport_IsDeterministicAndPrivateWithoutChangingSources() throws {
        let directory = try root()
        let source = try snapshot(directory)
        let original = try Data(contentsOf: XCTUnwrap(source.files["recordings/test.wav"]))
        let first = try MigrationTestArchive.export(source, digests: digests, stagingRoot: directory)
        let second = try MigrationTestArchive.export(source, digests: digests, stagingRoot: directory)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(source.files["recordings/test.wav"])), original)
        #if !os(Windows)
        let folder = try FileManager.default.attributesOfItem(atPath: first.deletingLastPathComponent().path)
        let file = try FileManager.default.attributesOfItem(atPath: first.path)
        XCTAssertEqual(folder[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
        XCTAssertEqual(file[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
        #endif
    }

    func testLongUnicodeAudioName_IsEmittedAndReadWithoutTruncation() throws {
        let directory = try root()
        let source = try MigrationTestArchive.read(
            MigrationArchiveFixtures.url("long-unicode"), digests: digests, stagingRoot: directory
        )
        let file = try MigrationTestArchive.export(source, digests: digests, stagingRoot: directory)
        let result = try MigrationTestArchive.read(file, digests: digests, stagingRoot: directory)
        XCTAssertEqual(result.records, source.records)
        XCTAssertEqual(Set(result.files.keys), Set(source.files.keys))
        XCTAssertTrue(result.notices.isEmpty)
    }

    func testCredentialExport_RequiresExplicitOptInAndCannotHideInSettings() throws {
        let directory = try root()
        let record = DataMigrationRecord(id: "synthetic-key", kind: "secret", value: AnyCodable(.string("synthetic")))
        var source = DataMigrationSnapshot(
            manifest: .init(categories: [.credentials], scopes: [:]), records: [.credentials: [record]]
        )
        XCTAssertThrowsError(try MigrationTestArchive.export(source, digests: digests, stagingRoot: directory))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let file = try MigrationTestArchive.export(
            source, digests: digests, stagingRoot: directory, includeCredentials: true
        )
        XCTAssertEqual(try MigrationTestArchive.read(file, digests: digests, stagingRoot: directory)
            .records[.credentials], [record])
        source.manifest.categories = [.settings]
        source.records = [.settings: [record]]
        XCTAssertThrowsError(try MigrationTestArchive.export(
            source, digests: digests, stagingRoot: directory, includeCredentials: true
        ))
    }

    func testMissingAndDamagedCategories_CannotBecomeValidEmptyExports() throws {
        let directory = try root()
        let source = DataMigrationSnapshot(manifest: .init(categories: [.settings], scopes: [:]), records: [:])
        XCTAssertThrowsError(try MigrationTestArchive.export(source, digests: digests, stagingRoot: directory))
        var damaged = source
        damaged.records = [.settings: []]
        damaged.notices = ["Settings & shortcuts, item 1: skipped invalid item."]
        XCTAssertThrowsError(try MigrationTestArchive.export(damaged, digests: digests, stagingRoot: directory))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        damaged.notices = []
        let file = try MigrationTestArchive.export(damaged, digests: digests, stagingRoot: directory)
        XCTAssertEqual(try MigrationTestArchive.read(file, digests: digests, stagingRoot: directory)
            .records[.settings], [])
    }

    func testMissingDigestDuplicateAudioAndTraversal_FailBeforeCreatingExportStaging() throws {
        let directory = try root()
        let original = try snapshot(directory)
        let initial = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        for variant in 0..<3 {
            var source = original
            var audio = try XCTUnwrap(source.records[.recordings]?.first)
            if variant == 0 { audio.digest = nil }
            if variant == 1 { audio.file = "recordings/../outside.wav" }
            source.records[.recordings] = variant == 2 ? [audio, audio] : [audio]
            XCTAssertThrowsError(try MigrationTestArchive.export(source, digests: digests, stagingRoot: directory))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), initial)
        }
    }

    func testChangedRecordingAndUnavailableHashing_RemovePartialExportWithoutTouchingOriginal() throws {
        let directory = try root()
        let original = try snapshot(directory)
        let initial = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var changed = original
        changed.records[.recordings]?[0].digest = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try MigrationTestArchive.export(changed, digests: digests, stagingRoot: directory))
        let unavailable = LocalModelDigestProvider(name: "Synthetic unavailable provider") {
            throw LocalModelDigestError.unavailable("Synthetic export failure")
        }
        XCTAssertThrowsError(try MigrationTestArchive.export(original, digests: unavailable, stagingRoot: directory))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), initial)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(original.files["recordings/test.wav"])),
                       MigrationArchiveFixtures.audio)
    }

    func testPreCancelledExport_CreatesNoStaging() async throws {
        let directory = try root()
        let source = try snapshot(directory)
        let initial = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let digests = digests
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MigrationTestArchive.export(source, digests: digests, stagingRoot: directory)
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled export succeeded.")
        } catch is CancellationError {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), initial)
        }
    }

    func testCancellationDuringAudioHashing_RemovesPartialExport() async throws {
        let directory = try root()
        let source = try snapshot(directory)
        let initial = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let digests = LocalModelDigestProvider(name: "Cancel export during hashing") {
            ExportFixtureHasher(cancelOnUpdate: true)
        }
        let task = Task { try MigrationTestArchive.export(source, digests: digests, stagingRoot: directory) }
        do {
            _ = try await task.value
            XCTFail("A cancelled export succeeded.")
        } catch is CancellationError {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), initial)
        }
    }
}

private final class ExportFixtureHasher: LocalModelSHA256Hasher {
    private var bytes = Data()
    private let cancelOnUpdate: Bool

    init(cancelOnUpdate: Bool = false) { self.cancelOnUpdate = cancelOnUpdate }

    func update(_ buffer: UnsafeRawBufferPointer) throws {
        bytes.append(contentsOf: buffer)
        if cancelOnUpdate { withUnsafeCurrentTask { $0?.cancel() } }
    }

    func finish() throws -> String {
        guard bytes == MigrationArchiveFixtures.audio else {
            throw LocalModelDigestError.unavailable("Unexpected export fixture bytes.")
        }
        return "322c4e201fab5f3d6824ad826d4af6569fd198c267b4d0a7a075c4114a2b9371"
    }
}
