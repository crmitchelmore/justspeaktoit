import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostMigrationInspectionTests: XCTestCase {
    func testRealBackup_InspectsHistoryAndAudioWithoutChangingApplicationOrSource() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        let record = try await fixture.seed()
        await fixture.controller.beginMigrationExport(fixture.destination, includeAudio: true, using: fixture.adapter())
        await fixture.finish()
        let source = try Data(contentsOf: fixture.destination)
        let inspector = DesktopHostMigrationInspector(reader: .init {
            try DesktopMigrationArchive.read(
                $0, digests: BackupHostFixture.digests, stagingRoot: fixture.root, storage: BackupHostFixture.storage
            )
        }, digests: BackupHostFixture.digests, present: { report in
            XCTAssertEqual(report.categories.map(\.category), [.history, .recordings])
            XCTAssertEqual(report.categories.map(\.items), [1, 1])
            XCTAssertEqual(report.noticeCount, 0)
            XCTAssertEqual(report.mergePreview.map(\.category), [.history, .recordings])
            XCTAssertEqual(report.mergePreview.map { $0.changes?.existing }, [1, 1])
            XCTAssertEqual(report.mergePreview.map { $0.changes?.added }, [0, 0])
            XCTAssertEqual(report.mergePreview.map { $0.changes?.updated }, [0, 0])
            XCTAssertEqual(report.mergePreview.map { $0.changes?.retained }, [1, 1])
            XCTAssertTrue(report.text.contains("Read-only merge preview"))
            XCTAssertTrue(report.recordingHistoryOnly)
            XCTAssertTrue(report.text.contains("Separate speech-usage ledgers are excluded"))
            XCTAssertFalse(report.text.contains(record.id.uuidString))
        })
        await fixture.controller.beginMigrationInspection(fixture.destination, using: inspector)
        let task = await fixture.controller.migrationInspectionTask
        await task?.value
        let restored = try await fixture.controller.store.record(id: record.id)
        XCTAssertEqual(restored.processedText, record.processedText)
        XCTAssertEqual(try Data(contentsOf: fixture.destination), source)
        let children = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertFalse(children.contains { $0.hasPrefix("migration-") })
        let operations = await fixture.controller.activeOperations
        XCTAssertEqual(operations, 0)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Backup inspected") == true)
        await fixture.controller.close()
    }

    func testHeldReader_SettingsQueueCanCloseAndLateResultCannotPresent() async throws {
        let fixture = try BackupHostFixture(grace: .milliseconds(20))
        defer { fixture.remove() }
        _ = try await fixture.seed()
        let gate = BackupPublicationGate()
        defer { gate.release() }
        let inspector = heldInspector(fixture, gate: gate)
        let queue = DesktopSettingsQueue()
        await queue.submit {
            await fixture.controller.beginMigrationInspection(fixture.destination, using: inspector)
        }.value
        await gate.waitUntilHeld()
        let task = await fixture.controller.migrationInspectionTask
        let statuses = FakeLog.shared.allStatuses
        let report = await queue.read { await fixture.controller.close() }.value
        XCTAssertEqual(report.unfinishedOperations, 1)
        gate.release()
        await task?.value
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
        let operations = await fixture.controller.activeOperations
        XCTAssertEqual(operations, 0)
        let children = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertFalse(children.contains { $0.hasPrefix("migration-") })
    }

    func testHeldReader_CancelAndDuplicateAdmissionRetainOwnedWorker() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed()
        let gate = BackupPublicationGate()
        defer { gate.release() }
        let inspector = heldInspector(fixture, gate: gate)
        await fixture.controller.beginMigrationInspection(fixture.destination, using: inspector)
        await gate.waitUntilHeld()
        let task = await fixture.controller.migrationInspectionTask
        await fixture.controller.beginMigrationInspection(fixture.destination, using: inspector)
        let operations = await fixture.controller.activeOperations
        XCTAssertEqual(operations, 1)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("another operation or confirmation") == true)
        await fixture.controller.cancelTranscription()
        gate.release()
        await task?.value
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("inspection cancelled") == true)
        await fixture.controller.close()
    }

    func testPresentationFailure_IsExplicitAndDoesNotRetainBusyState() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed()
        let inspector = DesktopHostMigrationInspector(reader: .init { _ in
            try Self.emptySnapshot(fixture.root)
        }, present: { _ in throw DesktopHostError(message: "Synthetic native presentation failure.") })
        await fixture.controller.beginMigrationInspection(fixture.destination, using: inspector)
        let task = await fixture.controller.migrationInspectionTask
        await task?.value
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Could not show backup inspection") == true)
        let busy = await fixture.controller.busy
        let operations = await fixture.controller.activeOperations
        XCTAssertFalse(busy)
        XCTAssertEqual(operations, 0)
        await fixture.controller.close()
    }

    func testUnsupportedAndClosedHosts_DoNotReadOrPresent() async throws {
        let fixture = try BackupHostFixture()
        defer { fixture.remove() }
        _ = try await fixture.seed()
        await fixture.controller.beginMigrationInspection(fixture.destination)
        let operations = await fixture.controller.activeOperations
        XCTAssertEqual(operations, 0)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("unavailable on this host") == true)
        await fixture.controller.close()
        let statuses = FakeLog.shared.allStatuses
        let inspector = DesktopHostMigrationInspector(reader: .init { _ in
            XCTFail("A closed host must not inspect archives.")
            return try Self.emptySnapshot(fixture.root)
        }, present: { _ in XCTFail("A closed host must not show reports.") })
        await fixture.controller.beginMigrationInspection(fixture.destination, using: inspector)
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
    }

    private func heldInspector(
        _ fixture: BackupHostFixture, gate: BackupPublicationGate
    ) -> DesktopHostMigrationInspector {
        .init(reader: .init { _ in
            let snapshot = try Self.emptySnapshot(fixture.root)
            gate.hold()
            return snapshot
        }, present: { _ in XCTFail("A cancelled reader must not show a report.") })
    }

    private static func emptySnapshot(_ root: URL) throws -> DataMigrationSnapshot {
        let directory = root.appendingPathComponent("migration-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return .init(
            manifest: .init(categories: [.history], scopes: [:]), records: [.history: []], directory: directory
        )
    }
}
