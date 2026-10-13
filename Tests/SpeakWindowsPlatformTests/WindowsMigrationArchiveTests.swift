import Foundation
import SpeakCore
import SpeakDesktop
import SpeakTestSupport
import SpeakWindowsPlatform
import XCTest

final class WindowsMigrationArchiveTests: XCTestCase {
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
