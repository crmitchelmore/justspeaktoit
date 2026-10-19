import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostProfileBackupTests: XCTestCase {
    private let profileData = Data("""
    [{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","name":"Retained profile",
      "polishPrompt":"Exact\\nPrompt","transcriptionRouting":"future-route",
      "matchers":[{"kind":"future-matcher","value":"retained"}],"future":{"enabled":false,"count":0}}]
    """.utf8)

    func testExplicitProfiles_BackupRoundTripsOriginalValuesAndScope() async throws {
        let fixture = try BackupHostFixture(profileData: profileData)
        defer { fixture.remove() }
        _ = try await fixture.seed()
        await fixture.controller.beginMigrationExport(
            fixture.destination, selection: .init(includeAudio: false, includeProfiles: true), using: fixture.adapter()
        )
        await fixture.finish()
        let snapshot = try DesktopMigrationArchive.read(
            fixture.destination, digests: BackupHostFixture.digests, stagingRoot: fixture.root,
            storage: BackupHostFixture.storage
        )
        XCTAssertEqual(snapshot.manifest.categories, [.history, .profiles])
        XCTAssertEqual(snapshot.manifest.scopes["profiles"]?.selectedKinds, ["profile"])
        XCTAssertEqual(snapshot.records[.profiles]?.map(\.value),
                       try JSONDecoder().decode([AnyCodable].self, from: profileData))
        let file = fixture.controller.directory.appendingPathComponent(DesktopDictationProfileStore.filename)
        XCTAssertEqual(try Data(contentsOf: file), profileData)
        XCTAssertEqual(snapshot.records[.history]?.count, 1)
        await fixture.controller.close()
    }

    func testLegacyHistoryBackup_DoesNotReadOrIncludeUnselectedProfiles() async throws {
        let fixture = try BackupHostFixture(profileData: profileData)
        defer { fixture.remove() }
        _ = try await fixture.seed()
        let file = fixture.controller.directory.appendingPathComponent(DesktopDictationProfileStore.filename)
        let damaged = Data("[".utf8)
        try damaged.write(to: file)
        await fixture.controller.beginMigrationExport(
            fixture.destination, includeAudio: false, using: fixture.adapter()
        )
        await fixture.finish()
        let snapshot = try DesktopMigrationArchive.read(
            fixture.destination, digests: BackupHostFixture.digests, stagingRoot: fixture.root,
            storage: BackupHostFixture.storage
        )
        XCTAssertEqual(snapshot.manifest.categories, [.history])
        XCTAssertNil(snapshot.records[.profiles])
        XCTAssertNil(snapshot.manifest.scopes["profiles"])
        XCTAssertEqual(try Data(contentsOf: file), damaged)
        await fixture.controller.close()
    }

    func testDamagedSelectedProfiles_FailWithoutPublishingOrClearingHistory() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed()
        let file = fixture.controller.directory.appendingPathComponent(DesktopDictationProfileStore.filename)
        let damaged = Data("[".utf8)
        try damaged.write(to: file)
        await fixture.controller.beginMigrationExport(
            fixture.destination, selection: .init(includeAudio: false, includeProfiles: true), using: fixture.adapter()
        )
        await fixture.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(try Data(contentsOf: file), damaged)
        let retained = try await fixture.controller.store.records()
        XCTAssertEqual(retained.count, 1)
        let operations = await fixture.controller.activeOperations
        XCTAssertEqual(operations, 0)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Could not save backup") == true)
        await fixture.controller.close()
    }

    func testUnreadableProfilesPreservedOnStartup_AreNotExportedAsEmptyAuthority() async throws {
        let fixture = try BackupHostFixture(profileData: Data("[".utf8))
        defer { fixture.remove() }
        _ = try await fixture.seed()
        await fixture.controller.beginMigrationExport(
            fixture.destination, selection: .init(includeAudio: false, includeProfiles: true), using: fixture.adapter()
        )
        await fixture.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        let operations = await fixture.controller.activeOperations
        XCTAssertEqual(operations, 0)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("unreadable source is recovered") == true)
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.controller.directory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("profiles.json.unreadable-") })
        await fixture.controller.close()
    }

    func testHeldProfileBackup_BlocksProfileEditingAndCloseCancelsPublication() async throws {
        let fixture = try BackupHostFixture(grace: .milliseconds(20), profileData: profileData)
        defer { fixture.remove() }
        _ = try await fixture.seed()
        let gate = BackupPublicationGate()
        defer { gate.release() }
        let adapter = fixture.adapter { source, destination in
            gate.hold()
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: source, to: destination)
        }
        await fixture.controller.beginMigrationExport(
            fixture.destination, selection: .init(includeAudio: false, includeProfiles: true), using: adapter
        )
        await gate.waitUntilHeld()
        await fixture.controller.saveProfiles([])
        let file = fixture.controller.directory.appendingPathComponent(DesktopDictationProfileStore.filename)
        XCTAssertEqual(try Data(contentsOf: file), profileData)
        let task = await fixture.controller.migrationExportTask
        let statuses = FakeLog.shared.allStatuses
        let report = await fixture.controller.close()
        XCTAssertEqual(report.unfinishedOperations, 1)
        gate.release()
        await task?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
        XCTAssertEqual(try Data(contentsOf: file), profileData)
    }
}
