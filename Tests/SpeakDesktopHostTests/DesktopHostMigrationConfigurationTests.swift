import Foundation
import SpeakCore
@testable import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostMigrationConfigurationTests: XCTestCase {
    func testFullBackup_RestoresSettingsAndOptedInAPIKeysThroughTheHost() async throws {
        FakeLog.shared.reset()
        let source = try BackupHostFixture()
        let target = try BackupHostFixture()
        defer { source.remove(); target.remove() }
        _ = try await source.seed(audio: false)
        await target.controller.markReadyForSelfTest()
        let field = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == "voiceCommandsEnabled" })
        var entries = try await source.controller.configuration().entries
        let exported = entries[field] == "1" ? "0" : "1"
        entries[field] = exported
        try await source.controller.saveConfiguration(entries)
        let identifier = try XCTUnwrap(
            DesktopHostController<FakePlatform>.apiKeyCatalogEntries().first?.identifier
        )
        FakeLog.shared.setKey("SYNTHETIC-BACKUP-KEY", name: identifier)
        try await exportWithKeys(source)

        FakeLog.shared.setKey("SYNTHETIC-LOCAL-KEY", name: identifier)
        let restorer = DesktopHostMigrationRestorer(reader: .init {
            try DesktopMigrationArchive.read(
                $0, digests: BackupHostFixture.digests, stagingRoot: target.root, storage: BackupHostFixture.storage
            )
        }, digests: BackupHostFixture.digests, confirm: { _, text, offers in
            XCTAssertTrue(offers)
            XCTAssertFalse(text.contains("SYNTHETIC-BACKUP-KEY"))
            XCTAssertFalse(text.contains("SYNTHETIC-LOCAL-KEY"))
        })
        await target.controller.beginMigrationRestore(
            source.destination, using: restorer,
            configuration: target.controller.migrationRestoreSource(includeCredentials: true)
        )
        await finish(target)
        let pending = await target.controller.migrationWork.restoreConfirmation
        let token = try XCTUnwrap(pending?.id).uuidString
        XCTAssertEqual(FakeLog.shared.key(identifier), "SYNTHETIC-LOCAL-KEY")
        await target.controller.answerMigrationRestore(token, choice: 2, using: restorer)
        await finish(target)
        let restored = try await target.controller.configuration().entries
        XCTAssertEqual(restored[field], exported)
        XCTAssertEqual(FakeLog.shared.key(identifier), "SYNTHETIC-BACKUP-KEY")
        let status = try XCTUnwrap(FakeLog.shared.allStatuses.last)
        XCTAssertTrue(status.contains("settings updated"), status)
        XCTAssertTrue(status.contains("1 API key(s) saved"), status)
        await target.controller.close()
        await source.controller.close()
    }

    func testBackupWithoutOptIn_ReadsNoAPIKeys() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        FakeLog.shared.reset()
        let fragment = try await fixture.controller.migrationBackupConfiguration(
            .init(includeAudio: false, includeConfiguration: true)
        )
        XCTAssertNil(try XCTUnwrap(fragment).credentials)
        XCTAssertNotNil(fragment?.vocabularyDirectory)
        let historyOnly = try await fixture.controller.migrationBackupConfiguration(
            .init(includeAudio: true, includeProfiles: true)
        )
        XCTAssertNil(historyOnly)
        await fixture.controller.close()
    }

    private func exportWithKeys(_ source: BackupHostFixture) async throws {
        let selection = DesktopMigrationBackup.Selection(
            includeAudio: false, includeProfiles: true, includeConfiguration: true, includeCredentials: true
        )
        let fragment = try await source.controller.migrationBackupConfiguration(selection)
        let root = source.root
        let adapter = DesktopMigrationBackup.Adapter(
            digests: BackupHostFixture.digests,
            archiveWithCredentials: {
                try DesktopMigrationArchive.export(
                    $0, digests: BackupHostFixture.digests, stagingRoot: root, includeCredentials: $1,
                    storage: BackupHostFixture.storage
                )
            },
            publish: { try FileManager.default.copyItem(at: $0, to: $1) }
        )
        await source.controller.beginMigrationExport(
            source.destination, selection: selection, using: adapter, configuration: fragment
        )
        await source.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.destination.path))
    }

    private func finish(_ fixture: BackupHostFixture) async {
        let task = await fixture.controller.migrationWork.restoreTask
        await task?.value
    }
}
