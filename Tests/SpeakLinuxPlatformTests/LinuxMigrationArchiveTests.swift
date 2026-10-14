import Foundation
import SpeakCore
import SpeakDesktop
import SpeakLinuxPlatform
import SpeakTestSupport
import XCTest

final class LinuxMigrationArchiveTests: XCTestCase {
    func testArchiveExport_StreamsNativeGLibVerifiedAudioIntoReadableZIP64() throws {
        let source = try DesktopMigrationArchive.read(
            MigrationArchiveFixtures.url("long-unicode"), digests: LinuxSHA256Hasher.provider
        )
        let sourceDirectory = try XCTUnwrap(source.directory)
        addTeardownBlock { try FileManager.default.removeItem(at: sourceDirectory) }
        let file = try DesktopMigrationArchive.export(source, digests: LinuxSHA256Hasher.provider)
        addTeardownBlock { try FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try DesktopMigrationArchive.read(file, digests: LinuxSHA256Hasher.provider)
        let resultDirectory = try XCTUnwrap(result.directory)
        addTeardownBlock { try FileManager.default.removeItem(at: resultDirectory) }
        XCTAssertEqual(result.records, source.records)
        XCTAssertTrue(result.notices.isEmpty)
        for audio in result.files.values { XCTAssertEqual(try Data(contentsOf: audio), MigrationArchiveFixtures.audio) }
    }

    func testMigrationPlanner_UsesNativeGLibForMacCompatibleVariantIdentifiers() throws {
        let original = DataMigrationRecord(id: "session", kind: "history", value: AnyCodable(.string("Original")))
        let changed = DataMigrationRecord(
            id: "session", kind: "history", value: AnyCodable(.string("Changed")), revision: "changed"
        )
        let manifest = DataMigrationManifest(categories: [.history], scopes: [:])
        let result = try DesktopMigrationPlanner.plan(
            current: .init(manifest: manifest, records: [.history: [original]]),
            incoming: .init(manifest: manifest, records: [.history: [changed]]),
            modes: [.history: .merge], useImported: [], digests: LinuxSHA256Hasher.provider
        )
        XCTAssertEqual(result.records[.history]?.map(\.id), ["session", MigrationPlannerFixtures.changedID])
    }

    func testArchiveAudio_UsesNativeGLibVerificationAndGeneratedStaging() throws {
        let result = try DesktopMigrationArchive.read(
            MigrationArchiveFixtures.url("zip64"), digests: LinuxSHA256Hasher.provider
        )
        let directory = try XCTUnwrap(result.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try XCTUnwrap(result.files["recordings/test.wav"])
        XCTAssertEqual(try Data(contentsOf: file), MigrationArchiveFixtures.audio)
        XCTAssertTrue(result.notices.isEmpty)
    }
}
