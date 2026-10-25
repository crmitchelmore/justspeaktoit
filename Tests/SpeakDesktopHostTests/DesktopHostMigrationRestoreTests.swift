import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostMigrationRestoreTests: XCTestCase {
    func testRealZIP_RestoresHistoryTextWithoutAudioSettingsOrSourceMutation() async throws {
        FakeLog.shared.reset()
        let source = try BackupHostFixture()
        let target = try BackupHostFixture()
        defer { source.remove(); target.remove() }
        let original = try await source.seed()
        await source.controller.beginMigrationExport(source.destination, includeAudio: true, using: source.adapter())
        await source.finish()
        let sourceBytes = try Data(contentsOf: source.destination)
        await target.controller.markReadyForSelfTest()
        let before = await target.controller.settings
        let settingsFile = target.root.appendingPathComponent("Application").appendingPathComponent("settings.json")
        let settingsBytes = try JSONEncoder().encode(before)
        try settingsBytes.write(to: settingsFile)
        let restorer = DesktopHostMigrationRestorer(reader: .init {
            try DesktopMigrationArchive.read(
                $0, digests: BackupHostFixture.digests, stagingRoot: target.root, storage: BackupHostFixture.storage
            )
        }, digests: BackupHostFixture.digests, confirm: { _, text, offers in
            XCTAssertFalse(offers)
            XCTAssertFalse(text.contains(original.processedText ?? "Synthetic retained transcript."))
        })
        await target.controller.beginMigrationRestore(source.destination, using: restorer)
        await finish(target)
        let pending = await target.controller.migrationRestoreConfirmation
        let token = try XCTUnwrap(pending?.id).uuidString
        let prior = try await target.controller.store.records()
        XCTAssertTrue(prior.isEmpty)
        await target.controller.answerMigrationRestore(token, choice: 1, using: restorer)
        await finish(target)
        let records = try await target.controller.store.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.processedText, original.processedText)
        XCTAssertEqual(records.first?.audioFilename, "")
        XCTAssertNil(records.first?.originPlatform)
        let after = await target.controller.settings
        XCTAssertEqual(after.model, before.model)
        XCTAssertEqual(after.configuration, before.configuration)
        XCTAssertEqual(try Data(contentsOf: settingsFile), settingsBytes)
        XCTAssertEqual(try Data(contentsOf: source.destination), sourceBytes)
        await target.controller.close()
        await source.controller.close()
    }

    func testPreview_RequiresCurrentSingleUseConfirmationAndLeavesSettingsUnchanged() async throws {
        FakeLog.shared.reset()
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed()
        let before = await fixture.controller.settings
        let restorer = try restorer(fixture, confirm: { _, text, _ in
            for secret in ["SYNTHETIC-PRIVATE-PROFILE", "SYNTHETIC-PRIVATE-PROMPT", "SYNTHETIC-SECRET"] {
                XCTAssertFalse(text.contains(secret))
            }
            XCTAssertTrue(text.contains("Nothing has been written yet"))
        })
        await fixture.controller.beginMigrationRestore(fixture.destination, using: restorer)
        await finish(fixture)
        let store = await fixture.controller.profileStore
        XCTAssertTrue(try store.load().isEmpty)
        let pending = await fixture.controller.migrationRestoreConfirmation
        let token = try XCTUnwrap(pending?.id).uuidString
        await fixture.controller.answerMigrationRestore(UUID().uuidString, choice: 1, using: restorer)
        XCTAssertTrue(try store.load().isEmpty)
        let stillPending = await fixture.controller.migrationRestoreConfirmation
        XCTAssertEqual(stillPending?.id.uuidString, token)
        await fixture.controller.answerMigrationRestore(token, choice: 1, using: restorer)
        await finish(fixture)
        XCTAssertEqual(try store.load().map(\.name), ["SYNTHETIC-PRIVATE-PROFILE"])
        let after = await fixture.controller.settings
        XCTAssertEqual(after.model, before.model)
        XCTAssertEqual(after.configuration, before.configuration)
        let status = FakeLog.shared.allStatuses.last
        XCTAssertTrue(status?.contains("Settings, audio and credentials were not applied") == true)
        await fixture.controller.answerMigrationRestore(token, choice: 1, using: restorer)
        XCTAssertEqual(try store.load().count, 1)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("no longer current") == true)
        let children = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertFalse(children.contains { $0.hasPrefix("migration-") })
        await fixture.controller.close()
    }

    func testCancel_ConsumesPreviewWithoutWriting() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed()
        let restorer = try restorer(fixture)
        await fixture.controller.beginMigrationRestore(fixture.destination, using: restorer)
        await finish(fixture)
        let pending = await fixture.controller.migrationRestoreConfirmation
        let token = try XCTUnwrap(pending?.id).uuidString
        await fixture.controller.answerMigrationRestore(token, choice: 0, using: restorer)
        let store = await fixture.controller.profileStore
        XCTAssertTrue(try store.load().isEmpty)
        let remaining = await fixture.controller.migrationRestoreConfirmation
        XCTAssertNil(remaining)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Restore cancelled. Nothing was changed.") == true)
        await fixture.controller.close()
    }

    func testReplace_WhenNotOfferedCannotBeForged() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed()
        let restorer = try restorer(fixture, confirm: { _, _, offers in XCTAssertFalse(offers) })
        await fixture.controller.beginMigrationRestore(fixture.destination, using: restorer)
        await finish(fixture)
        let pending = await fixture.controller.migrationRestoreConfirmation
        let token = try XCTUnwrap(pending?.id).uuidString
        await fixture.controller.answerMigrationRestore(token, choice: 2, using: restorer)
        let store = await fixture.controller.profileStore
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Replace was not offered") == true)
        await fixture.controller.close()
    }

    func testReplace_ChangesOnlyProfilesAfterExplicitChoice() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        let history = try await fixture.seed()
        let store = await fixture.controller.profileStore
        try store.save([DictationProfile(name: "Existing", polishPrompt: nil)])
        let restorer = try restorer(fixture, confirm: { _, _, offers in XCTAssertTrue(offers) })
        await fixture.controller.beginMigrationRestore(fixture.destination, using: restorer)
        await finish(fixture)
        XCTAssertEqual(try store.load().map(\.name), ["Existing"])
        let pending = await fixture.controller.migrationRestoreConfirmation
        let token = try XCTUnwrap(pending?.id).uuidString
        await fixture.controller.answerMigrationRestore(token, choice: 2, using: restorer)
        await finish(fixture)
        XCTAssertEqual(try store.load().map(\.name), ["SYNTHETIC-PRIVATE-PROFILE"])
        let retained = try await fixture.controller.store.record(id: history.id)
        XCTAssertEqual(retained.processedText, history.processedText)
        await fixture.controller.close()
    }

    func testHeldReader_SettingsQueueCanCloseAndLateResultCannotPresent() async throws {
        let fixture = try BackupHostFixture(grace: .milliseconds(20))
        defer { fixture.remove() }
        _ = try await fixture.seed()
        let entered = expectation(description: "Restore entered the actual archive reader")
        let gate = MigrationRestoreReaderGate(entered)
        defer { gate.release() }
        let restorer = try restorer(fixture, hold: { gate.hold() }, confirm: { _, _, _ in
            XCTFail("A closed host must not present a late restore preview.")
        })
        let queue = DesktopSettingsQueue()
        await queue.submit {
            await fixture.controller.beginMigrationRestore(fixture.destination, using: restorer)
        }.value
        await fulfillment(of: [entered], timeout: 10)
        let task = await fixture.controller.migrationRestoreTask
        let report = await queue.read { await fixture.controller.close() }.value
        XCTAssertEqual(report.unfinishedOperations, 1)
        gate.release()
        await task?.value
        let operations = await fixture.controller.activeOperations
        XCTAssertEqual(operations, 0)
        let children = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertFalse(children.contains { $0.hasPrefix("migration-") })
    }

    func testPreviewFailure_ReleasesConfirmationAndBusyState() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed()
        let restorer = try restorer(fixture, confirm: { _, _, _ in
            throw DesktopHostError(message: "Synthetic preview failure.")
        })
        await fixture.controller.beginMigrationRestore(fixture.destination, using: restorer)
        await finish(fixture)
        let pending = await fixture.controller.migrationRestoreConfirmation
        let busy = await fixture.controller.busy
        let operations = await fixture.controller.activeOperations
        XCTAssertNil(pending)
        XCTAssertFalse(busy)
        XCTAssertEqual(operations, 0)
        let store = await fixture.controller.profileStore
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Could not show the restore preview") == true)
        await fixture.controller.close()
    }

    private func finish(_ fixture: BackupHostFixture) async {
        let task = await fixture.controller.migrationRestoreTask
        await task?.value
    }

    private func restorer(
        _ fixture: BackupHostFixture, hold: @escaping @Sendable () -> Void = {},
        confirm: @escaping @Sendable (String, String, Bool) throws -> Void = { _, _, _ in }
    ) throws -> DesktopHostMigrationRestorer {
        try Data("Synthetic archive reader input.".utf8).write(to: fixture.destination)
        return .init(reader: .init { _ in
            let staging = fixture.root.appendingPathComponent("migration-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            let profile = DictationProfile(name: "SYNTHETIC-PRIVATE-PROFILE", polishPrompt: "SYNTHETIC-PRIVATE-PROMPT")
            let record = DataMigrationRecord(
                id: profile.id.uuidString, kind: DataMigrationProfileCatalog.kind,
                value: try DataMigrationCoding.value(profile)
            )
            let secret = DataMigrationRecord(
                id: "synthetic", kind: "credential", value: AnyCodable(.string("SYNTHETIC-SECRET"))
            )
            hold()
            return DataMigrationSnapshot(
                manifest: .init(categories: [.profiles, .settings, .credentials], scopes: [:]),
                records: [.profiles: [record], .credentials: [secret]], directory: staging
            )
        }, digests: BackupHostFixture.digests, confirm: confirm)
    }
}

private final class MigrationRestoreReaderGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let entered: XCTestExpectation
    private var released = false

    init(_ entered: XCTestExpectation) { self.entered = entered }

    func hold() {
        condition.lock()
        defer { condition.unlock() }
        entered.fulfill()
        let deadline = Date().addingTimeInterval(30)
        while !released {
            let signaled = condition.wait(until: deadline)
            if !released && !signaled {
                XCTFail("Restore reader was not released before the emergency deadline.")
                return
            }
        }
    }

    func release() {
        condition.lock()
        defer { condition.unlock() }
        released = true
        condition.broadcast()
    }
}
