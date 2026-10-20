import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostMigrationExportTests: XCTestCase {
    func testHistoryAndAudioBackup_RoundTripsRealStoreAndRemovesOwnedStaging() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        let record = try await fixture.seed()
        await fixture.controller.beginMigrationExport(fixture.destination, includeAudio: true, using: fixture.adapter())
        await fixture.finish()
        let snapshot = try DesktopMigrationArchive.read(
            fixture.destination, digests: BackupHostFixture.digests, stagingRoot: fixture.root,
            storage: BackupHostFixture.storage
        )
        let incoming = try XCTUnwrap(snapshot.records[.history]?.first)
        let restored = try DesktopMigrationHistory.record(incoming, category: .history, audioFilename: "restored.wav")
        XCTAssertEqual(restored.id, record.id)
        XCTAssertEqual(restored.processedText, record.processedText)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(snapshot.files.values.first)), Data([1, 2, 3]))
        let children = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertFalse(children.contains { $0.hasPrefix("migration-export-") })
        let operations = await fixture.controller.activeOperations
        XCTAssertEqual(operations, 0)
        await fixture.controller.close()
    }

    func testMissingAudio_FailsCompleteBackupButAllowsExplicitHistoryOnly() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed(audio: false)
        await fixture.controller.beginMigrationExport(fixture.destination, includeAudio: true, using: fixture.adapter())
        await fixture.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        await fixture.controller.beginMigrationExport(
            fixture.destination, includeAudio: false, using: fixture.adapter()
        )
        await fixture.finish()
        let snapshot = try DesktopMigrationArchive.read(
            fixture.destination, digests: BackupHostFixture.digests, stagingRoot: fixture.root,
            storage: BackupHostFixture.storage
        )
        XCTAssertEqual(snapshot.manifest.categories, [.history])
        XCTAssertEqual(snapshot.records[.history]?.count, 1)
        await fixture.controller.close()
    }

    func testExistingDestination_IsPreservedAndStagingRemovedAfterFailure() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        let existing = Data("Existing synthetic backup".utf8)
        try existing.write(to: fixture.destination)
        _ = try await fixture.seed()
        await fixture.controller.beginMigrationExport(
            fixture.destination, includeAudio: false, using: fixture.adapter()
        )
        await fixture.finish()
        XCTAssertEqual(try Data(contentsOf: fixture.destination), existing)
        let children = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertFalse(children.contains { $0.hasPrefix("migration-export-") })
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Could not save History backup") == true)
        await fixture.controller.close()
    }

    func testHeldPublication_CloseIsBoundedAndLateResultCannotPublishOrReachUI() async throws {
        let fixture = try BackupHostFixture(grace: .milliseconds(20))
        defer { fixture.remove() }
        _ = try await fixture.seed()
        let gate = BackupPublicationGate()
        defer { gate.release() }
        let adapter = fixture.adapter { source, target in
            gate.hold()
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: source, to: target)
        }
        let queue = DesktopSettingsQueue()
        await queue.submit {
            await fixture.controller.beginMigrationExport(fixture.destination, includeAudio: true, using: adapter)
        }.value
        await gate.waitUntilHeld()
        let task = await fixture.controller.migrationExportTask
        let statuses = FakeLog.shared.allStatuses
        let report = await queue.read { await fixture.controller.close() }.value
        XCTAssertEqual(report.unfinishedOperations, 1)
        gate.release()
        await task?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
        let operations = await fixture.controller.activeOperations
        XCTAssertEqual(operations, 0)
    }

    func testCancellationAfterCommit_ReportsSavedAndKeepsDestination() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed()
        let gate = BackupPublicationGate()
        defer { gate.release() }
        let adapter = fixture.adapter { source, target in
            try FileManager.default.copyItem(at: source, to: target)
            gate.hold()
        }
        await fixture.controller.beginMigrationExport(fixture.destination, includeAudio: false, using: adapter)
        await gate.waitUntilHeld()
        await fixture.controller.cancelTranscription()
        gate.release()
        await fixture.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.hasPrefix("Saved History text backup") == true)
        await fixture.controller.close()
    }

    func testUnsupportedAndClosedHosts_DoNotAdmitBackupWork() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed()
        await fixture.controller.beginMigrationExport(fixture.destination, includeAudio: false)
        let unsupportedOperations = await fixture.controller.activeOperations
        XCTAssertEqual(unsupportedOperations, 0)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("unavailable on this host") == true)
        await fixture.controller.close()
        let statuses = FakeLog.shared.allStatuses
        await fixture.controller.beginMigrationExport(
            fixture.destination, includeAudio: false, using: fixture.adapter()
        )
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testBusyHost_RejectsSecondAdmissionWithoutReplacingOwnedWorker() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed()
        let gate = BackupPublicationGate()
        defer { gate.release() }
        let adapter = fixture.adapter { source, target in
            gate.hold()
            try FileManager.default.copyItem(at: source, to: target)
        }
        await fixture.controller.beginMigrationExport(fixture.destination, includeAudio: false, using: adapter)
        await gate.waitUntilHeld()
        let second = fixture.root.appendingPathComponent("Second backup.zip")
        await fixture.controller.beginMigrationExport(second, includeAudio: false, using: fixture.adapter())
        let operations = await fixture.controller.activeOperations
        XCTAssertEqual(operations, 1)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("another operation") == true)
        gate.release()
        await fixture.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        await fixture.controller.close()
    }

    func testInvalidStagingProducer_DoesNotDeleteUnownedParentOrPublish() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed()
        let unowned = fixture.root.appendingPathComponent("Keep this file.zip")
        let expected = Data("Unowned synthetic data".utf8)
        try expected.write(to: unowned)
        let adapter = DesktopMigrationBackup.Adapter(
            digests: BackupHostFixture.digests, archive: { _ in unowned },
            publish: { _, _ in XCTFail("An invalid staging path must never reach publication.") }
        )
        await fixture.controller.beginMigrationExport(fixture.destination, includeAudio: false, using: adapter)
        await fixture.finish()
        XCTAssertEqual(try Data(contentsOf: unowned), expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("invalid owned staging path") == true)
        await fixture.controller.close()
    }

    func testCommittedWarning_ReportsSavedAndCleansOwnedStaging() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed()
        let adapter = fixture.adapter { source, target in
            try FileManager.default.copyItem(at: source, to: target)
            throw DesktopFilePublication.CopyCompletionFailure(
                destination: target, detail: "Synthetic post-commit durability warning."
            )
        }
        await fixture.controller.beginMigrationExport(fixture.destination, includeAudio: false, using: adapter)
        await fixture.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.hasPrefix("Saved History text backup") == true)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("durability warning") == true)
        let children = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertFalse(children.contains { $0.hasPrefix("migration-export-") })
        await fixture.controller.close()
    }

    func testPrecancelledService_DoesNotCreateOrPublishArchive() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        let store = await fixture.controller.store
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await DesktopMigrationBackup.export(
                store: store, destination: fixture.destination, includeAudio: false, adapter: fixture.adapter()
            )
        }
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        let children = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertFalse(children.contains { $0.hasPrefix("migration-export-") })
        await fixture.controller.close()
    }

    func testPendingAudioConfirmation_RefusesBackupWithoutChangingConfirmation() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed()
        await fixture.controller.beginAudioCleanupConfirmation()
        let preparing = await fixture.controller.audioCleanupTask
        await preparing?.value
        let confirmation = await fixture.controller.audioCleanupConfirmation?.id
        XCTAssertNotNil(confirmation)
        await fixture.controller.beginMigrationExport(
            fixture.destination, includeAudio: false, using: fixture.adapter()
        )
        let remaining = await fixture.controller.audioCleanupConfirmation?.id
        let operations = await fixture.controller.activeOperations
        XCTAssertEqual(remaining, confirmation)
        XCTAssertEqual(operations, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("another operation or confirmation") == true)
        await fixture.controller.close()
    }
}

struct BackupHostFixture {
    let root: URL
    let controller: DesktopHostController<FakePlatform>
    var destination: URL { root.appendingPathComponent("History backup.zip") }
    static let digests = LocalModelDigestProvider(name: "Synthetic fixed digest; not cryptographic proof") {
        BackupFixtureDigest()
    }
    static let storage = DesktopMigrationArchive.Storage(
        createDirectory: {
            try FileManager.default.createDirectory(
                at: $0, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
        },
        createFile: {
            guard FileManager.default.createFile(
                atPath: $0.path, contents: Data(), attributes: [.posixPermissions: 0o600]
            )
            else { throw CocoaError(.fileWriteUnknown) }
        }
    )

    init(grace: Duration = .seconds(5), profileData: Data? = nil) throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("backup-host-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        if let profileData {
            let directory = root.appendingPathComponent("Application")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try profileData.write(to: directory.appendingPathComponent(DesktopDictationProfileStore.filename))
        }
        controller = try DesktopHostController<FakePlatform>(
            directory: root.appendingPathComponent("Application"), effects: SyntheticEffects(), shutdownGrace: grace
        )
    }

    func adapter(
        publish: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    ) -> DesktopMigrationBackup.Adapter {
        .init(
            digests: Self.digests,
            archive: { try DesktopMigrationArchive.export(
                $0, digests: Self.digests, stagingRoot: root, storage: Self.storage
            ) },
            publish: publish
        )
    }

    func seed(audio: Bool = true) async throws -> DesktopRecordingStore.Record {
        await controller.markReadyForSelfTest()
        let id = UUID()
        var record = DesktopRecordingStore.Record(
            id: id, audioFilename: "\(id).wav", modelIdentifier: "synthetic/model"
        )
        record.processedText = "Synthetic retained transcript."
        let directory = await controller.store.directory
        if audio { try Data([1, 2, 3]).write(to: directory.appendingPathComponent(record.audioFilename)) }
        try await controller.store.save(record)
        await controller.indexHistory(record)
        return record
    }

    func finish() async {
        let task = await controller.migrationExportTask
        await task?.value
    }

    func remove() {
        do { try FileManager.default.removeItem(at: root) } catch { XCTFail(error.localizedDescription) }
    }
}

private final class BackupFixtureDigest: LocalModelSHA256Hasher {
    func update(_ bytes: UnsafeRawBufferPointer) throws { try Task.checkCancellation() }
    func finish() throws -> String { String(repeating: "a", count: 64) }
}

final class BackupPublicationGate: @unchecked Sendable {
    private let arrived = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func hold() {
        arrived.signal()
        released.wait()
    }

    func waitUntilHeld() async { await Task.detached { self.arrived.wait() }.value }
    func release() { released.signal() }
}
