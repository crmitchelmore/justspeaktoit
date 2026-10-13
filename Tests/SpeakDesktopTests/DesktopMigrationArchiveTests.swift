import Foundation
import SpeakCore
import SpeakTestSupport
import XCTest
@testable import SpeakDesktop

final class DesktopMigrationArchiveTests: XCTestCase {
    private let digests = LocalModelDigestProvider(name: "Synthetic fixture verifier") { FixtureHasher() }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    func testStoredDeflateAndZIP64_ReadCanonicalManifestRecordsAndAudio() throws {
        for name in ["stored", "deflate", "zip64"] {
            let result = try DesktopMigrationArchive.read(
                MigrationArchiveFixtures.url(name), digests: digests, stagingRoot: root()
            )
            XCTAssertEqual(result.manifest.format, "JustSpeakToIt")
            XCTAssertEqual(result.manifest.categories, [.settings, .recordings])
            XCTAssertEqual(result.records[.settings]?.first?.id, "appearance")
            XCTAssertEqual(result.records[.recordings]?.count, 1)
            let audio = try XCTUnwrap(result.files["recordings/test.wav"])
            XCTAssertEqual(try Data(contentsOf: audio), MigrationArchiveFixtures.audio)
            XCTAssertNotEqual(audio.lastPathComponent, "test.wav")
            XCTAssertNotNil(UUID(uuidString: audio.deletingPathExtension().lastPathComponent))
            XCTAssertTrue(result.notices.isEmpty)
        }
    }

    func testLongUnicodeName_IsNotTruncatedIntoAnotherEntryOrDestination() throws {
        let result = try DesktopMigrationArchive.read(
            MigrationArchiveFixtures.url("long-unicode"), digests: digests, stagingRoot: root()
        )
        let path = "recordings/" + String(repeating: "\u{00F1}", count: 260) + ".wav"
        XCTAssertEqual(Set(result.files.keys), [path])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.files[path])), MigrationArchiveFixtures.audio)
        XCTAssertTrue(result.notices.isEmpty)
    }

    func testDuplicateArchivePathsAndManifestCRC_RejectBeforeStaging() throws {
        for name in ["duplicate-path", "bad-manifest-crc"] {
            let staging = try root()
            XCTAssertThrowsError(try DesktopMigrationArchive.read(
                MigrationArchiveFixtures.url(name), digests: digests, stagingRoot: staging
            ))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        }
    }

    func testInvalidAudioCRCAndDigest_LeaveNoPartialRecording() throws {
        for name in ["bad-audio-crc", "bad-digest"] {
            let result = try DesktopMigrationArchive.read(
                MigrationArchiveFixtures.url(name), digests: digests, stagingRoot: root()
            )
            XCTAssertEqual(result.records[.recordings], [])
            XCTAssertTrue(result.files.isEmpty)
            XCTAssertEqual(result.notices.count, 1)
            let directory = try XCTUnwrap(result.directory)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            XCTAssertEqual(result.records[.settings]?.count, 1)
        }
    }

    func testTraversalAndSymlinks_AreReportedWithoutMaterialization() throws {
        for name in ["traversal", "symlink"] {
            let result = try DesktopMigrationArchive.read(
                MigrationArchiveFixtures.url(name), digests: digests, stagingRoot: root()
            )
            XCTAssertTrue(result.files.isEmpty)
            XCTAssertEqual(result.records[.recordings], [])
            XCTAssertEqual(result.notices.count, 1)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(
                atPath: XCTUnwrap(result.directory).path
            ).isEmpty)
        }
    }

    func testDuplicateReferenceAndInvalidItem_PreserveValidDataAndReportPartialImport() throws {
        for name in ["duplicate-recording", "invalid-item"] {
            let result = try DesktopMigrationArchive.read(
                MigrationArchiveFixtures.url(name), digests: digests, stagingRoot: root()
            )
            XCTAssertEqual(result.records[.recordings]?.count, 1)
            XCTAssertEqual(result.files.count, 1)
            XCTAssertEqual(result.notices.count, 1)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(
                atPath: XCTUnwrap(result.directory).path
            ).count, 1)
        }
    }

    func testMissingCategory_RemainsAbsentToPreventDestructiveReplacement() throws {
        let result = try DesktopMigrationArchive.read(
            MigrationArchiveFixtures.url("missing-category"), digests: digests, stagingRoot: root()
        )
        XCTAssertNil(result.records[.settings])
        XCTAssertEqual(result.records[.recordings]?.count, 1)
        XCTAssertEqual(result.notices, [
            "Settings & shortcuts: category could not be read; existing data will be preserved."
        ])
    }

    func testNativeIndexBudget_RejectsExplicitlyInsteadOfAllocatingUnboundedMemory() throws {
        XCTAssertThrowsError(try DesktopMigrationZipReader(
            source: MigrationArchiveFixtures.url("deflate"), indexMemoryBudget: 1
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("memory budget"), error.localizedDescription)
        }
    }

    func testUnavailableDigestProvider_AbortsAndRemovesStagingRatherThanSkippingAudio() throws {
        let staging = try root()
        let unavailable = LocalModelDigestProvider(name: "Unavailable fixture provider") {
            throw LocalModelDigestError.unavailable("Synthetic provider failure.")
        }
        XCTAssertThrowsError(try DesktopMigrationArchive.read(
            MigrationArchiveFixtures.url("deflate"), digests: unavailable, stagingRoot: staging
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("Synthetic provider failure."))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    func testPreCancelledRead_DoesNotCreatePrivateStaging() async throws {
        let staging = try root()
        let fixture = try MigrationArchiveFixtures.url("deflate")
        let digests = digests
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DesktopMigrationArchive.read(fixture, digests: digests, stagingRoot: staging)
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled archive read succeeded.")
        } catch is CancellationError {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        }
    }

    func testCancellationDuringDigest_RemovesAllPrivateStaging() async throws {
        let staging = try root()
        let fixture = try MigrationArchiveFixtures.url("deflate")
        let digests = LocalModelDigestProvider(name: "Cancel during verification") {
            FixtureHasher(cancelOnUpdate: true)
        }
        let task = Task { try DesktopMigrationArchive.read(fixture, digests: digests, stagingRoot: staging) }
        do {
            _ = try await task.value
            XCTFail("A cancelled audio verification succeeded.")
        } catch is CancellationError {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        }
    }
}

private final class FixtureHasher: LocalModelSHA256Hasher {
    private var bytes = Data()
    private let cancelOnUpdate: Bool

    init(cancelOnUpdate: Bool = false) { self.cancelOnUpdate = cancelOnUpdate }

    func update(_ buffer: UnsafeRawBufferPointer) throws {
        bytes.append(contentsOf: buffer)
        if cancelOnUpdate { withUnsafeCurrentTask { $0?.cancel() } }
    }

    func finish() throws -> String {
        guard bytes == MigrationArchiveFixtures.audio else {
            throw LocalModelDigestError.unavailable("Unexpected synthetic fixture bytes.")
        }
        return "322c4e201fab5f3d6824ad826d4af6569fd198c267b4d0a7a075c4114a2b9371"
    }
}
