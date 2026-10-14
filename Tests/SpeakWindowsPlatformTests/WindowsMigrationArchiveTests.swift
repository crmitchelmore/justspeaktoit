import Foundation
import SpeakCore
import SpeakDesktop
import SpeakTestSupport
import SpeakWindowsPlatform
import XCTest

final class WindowsMigrationArchiveTests: XCTestCase {
    func testArchiveExport_StreamsNativeCNGVerifiedAudioIntoReadableZIP64() throws {
        #if os(Windows)
        let source = try DesktopMigrationArchive.read(
            MigrationArchiveFixtures.url("long-unicode"), digests: WindowsSHA256Hasher.provider
        )
        let sourceDirectory = try XCTUnwrap(source.directory)
        addTeardownBlock { try FileManager.default.removeItem(at: sourceDirectory) }
        let file = try DesktopMigrationArchive.export(source, digests: WindowsSHA256Hasher.provider)
        addTeardownBlock { try FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let result = try DesktopMigrationArchive.read(file, digests: WindowsSHA256Hasher.provider)
        let resultDirectory = try XCTUnwrap(result.directory)
        addTeardownBlock { try FileManager.default.removeItem(at: resultDirectory) }
        XCTAssertEqual(result.records, source.records)
        XCTAssertTrue(result.notices.isEmpty)
        for audio in result.files.values { XCTAssertEqual(try Data(contentsOf: audio), MigrationArchiveFixtures.audio) }
        #else
        throw XCTSkip("Requires the native Windows CNG adapter.")
        #endif
    }

    func testMigrationPlanner_UsesNativeCNGForMacCompatibleVariantIdentifiers() throws {
        #if os(Windows)
        let original = DataMigrationRecord(id: "session", kind: "history", value: AnyCodable(.string("Original")))
        let changed = DataMigrationRecord(
            id: "session", kind: "history", value: AnyCodable(.string("Changed")), revision: "changed"
        )
        let manifest = DataMigrationManifest(categories: [.history], scopes: [:])
        let result = try DesktopMigrationPlanner.plan(
            current: .init(manifest: manifest, records: [.history: [original]]),
            incoming: .init(manifest: manifest, records: [.history: [changed]]),
            modes: [.history: .merge], useImported: [], digests: WindowsSHA256Hasher.provider
        )
        XCTAssertEqual(result.records[.history]?.map(\.id), ["session", MigrationPlannerFixtures.changedID])
        #else
        throw XCTSkip("Requires the native Windows CNG adapter.")
        #endif
    }

    func testArchiveAudio_UsesNativeCNGVerificationAndGeneratedStaging() throws {
        #if os(Windows)
        let result = try DesktopMigrationArchive.read(
            MigrationArchiveFixtures.url("zip64"), digests: WindowsSHA256Hasher.provider
        )
        let directory = try XCTUnwrap(result.directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try XCTUnwrap(result.files["recordings/test.wav"])
        XCTAssertEqual(try Data(contentsOf: file), MigrationArchiveFixtures.audio)
        XCTAssertTrue(result.notices.isEmpty)
        #else
        throw XCTSkip("Requires the native Windows CNG adapter.")
        #endif
    }
}
