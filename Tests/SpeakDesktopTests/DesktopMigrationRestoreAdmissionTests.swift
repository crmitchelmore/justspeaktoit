import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop

final class DesktopMigrationRestoreAdmissionTests: XCTestCase {
    func testUpdatedHistoryAfterPlanningIsPreservedAtStoreAdmission() async throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        let id = UUID()
        try await fixture.store.save(RestoreFixture.native(id, text: nil))
        let incoming = RestoreFixture.snapshot([.history: [try RestoreFixture.history(id, text: "Backup")]])
        let plan = try await DesktopMigrationRestore.plan(incoming, targets: fixture.targets)
        let guards = try await fixture.store.migrationRestoreGuards()
        let writes = try DesktopMigrationRestore.compute(
            plan.incoming, baseline: plan.baseline, choice: .merge, guards: guards, digests: RestoreFixture.digests
        ).history
        XCTAssertEqual(writes.count, 1)
        try await fixture.store.save(RestoreFixture.native(id, text: "Newer local text"))
        let before = try Data(contentsOf: fixture.historyFile(id))
        do {
            _ = try await fixture.store.applyMigrationRestore(
                writes, expectedHistory: plan.baseline.history, digests: RestoreFixture.digests,
                checkpoint: { _ in XCTFail("A stale plan must be rejected before write checkpoints.") }
            )
            XCTFail("A stale plan must not replace newer History.")
        } catch is DesktopMigrationRestore.StaleHistory {
            XCTAssertEqual(try Data(contentsOf: fixture.historyFile(id)), before)
        }
    }

    func testNewHistoryAfterPlanningRefusesEvenAnUnrelatedPendingWrite() async throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        let restored = UUID()
        let incoming = RestoreFixture.snapshot([.history: [try RestoreFixture.history(restored, text: "Backup")]])
        let plan = try await DesktopMigrationRestore.plan(incoming, targets: fixture.targets)
        let guards = try await fixture.store.migrationRestoreGuards()
        let writes = try DesktopMigrationRestore.compute(
            plan.incoming, baseline: plan.baseline, choice: .merge, guards: guards, digests: RestoreFixture.digests
        ).history
        let concurrent = UUID()
        try await fixture.store.save(RestoreFixture.native(concurrent, text: "New recording"))
        do {
            _ = try await fixture.store.applyMigrationRestore(
                writes, expectedHistory: plan.baseline.history, digests: RestoreFixture.digests, checkpoint: { _ in }
            )
            XCTFail("An added History item must invalidate the full preview baseline.")
        } catch is DesktopMigrationRestore.StaleHistory {
            let records = try await fixture.store.records()
            XCTAssertEqual(records.map(\.id), [concurrent])
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.historyFile(restored).path))
        }
    }

    func testStoreAdmissionIgnoresEnumerationOrderButStillWritesUnchangedHistory() async throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        let ids = [UUID(), UUID()]
        for id in ids { try await fixture.store.save(RestoreFixture.native(id, text: nil)) }
        let incoming = RestoreFixture.snapshot([
            .history: try ids.map { try RestoreFixture.history($0, text: "Restored") }
        ])
        let plan = try await DesktopMigrationRestore.plan(incoming, targets: fixture.targets)
        let guards = try await fixture.store.migrationRestoreGuards()
        let writes = try DesktopMigrationRestore.compute(
            plan.incoming, baseline: plan.baseline, choice: .merge, guards: guards, digests: RestoreFixture.digests
        ).history
        let written = try await fixture.store.applyMigrationRestore(
            writes, expectedHistory: Array(plan.baseline.history.reversed()), digests: RestoreFixture.digests,
            checkpoint: { _ in }
        )
        XCTAssertEqual(Set(written.map(\.id)), Set(ids))
        XCTAssertTrue(written.allSatisfy { $0.processedText == "Restored" })
    }

    func testLateHistoryChangeRollsBackProfilesAndReportsStale() async throws {
        for existingProfiles in [false, true] {
            let fixture = try RestoreFixture()
            defer { fixture.remove() }
            if existingProfiles { try fixture.profiles.save([DictationProfile(name: "Existing", polishPrompt: nil)]) }
            let prior = existingProfiles ? try Data(contentsOf: fixture.profiles.fileURL) : nil
            let id = UUID()
            try await fixture.store.save(RestoreFixture.native(id, text: nil))
            let incoming = RestoreFixture.snapshot([
                .history: [try RestoreFixture.history(id, text: "Backup")],
                .profiles: [try RestoreFixture.profile(DictationProfile(name: "Incoming", polishPrompt: nil))]
            ])
            let plan = try await DesktopMigrationRestore.plan(incoming, targets: fixture.targets)
            let path = fixture.historyFile(id)
            let concurrent = try JSONEncoder().encode(RestoreFixture.native(id, text: "Concurrent edit"))
            let outcome = await DesktopMigrationRestore.apply(
                plan, choice: .replace, targets: fixture.targets,
                checkpoint: { step in
                    if step == .profiles { try concurrent.write(to: path, options: .atomic) }
                }
            )
            guard case let .stale(message) = outcome else { return XCTFail("\(outcome)") }
            XCTAssertTrue(message.contains("Nothing was restored"))
            XCTAssertEqual(try Data(contentsOf: path), concurrent)
            if let prior {
                XCTAssertEqual(try Data(contentsOf: fixture.profiles.fileURL), prior)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.profiles.fileURL.path))
            }
        }
    }

    func testStaleFailureWithUnrestoredProfilesIsNotReportedAsSafeToRetry() async throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        try fixture.profiles.save([DictationProfile(name: "Existing", polishPrompt: nil)])
        let id = UUID()
        let incoming = RestoreFixture.snapshot([
            .history: [try RestoreFixture.history(id, text: "Backup")],
            .profiles: [try RestoreFixture.profile(DictationProfile(name: "Incoming", polishPrompt: nil))]
        ])
        let plan = try await DesktopMigrationRestore.plan(incoming, targets: fixture.targets)
        let profileFile = fixture.profiles.fileURL
        let outcome = await DesktopMigrationRestore.apply(
            plan, choice: .replace, targets: fixture.targets,
            checkpoint: { step in
                if step == .history(0) {
                    try FileManager.default.removeItem(at: profileFile)
                    try FileManager.default.createDirectory(at: profileFile, withIntermediateDirectories: false)
                    throw DesktopMigrationRestore.StaleHistory()
                }
            }
        )
        guard case let .failed(restored, message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(restored)
        XCTAssertTrue(message.contains("History changed after the preview"))
        XCTAssertTrue(message.contains("Rollback could not restore: app profiles"))
        XCTAssertFalse(message.contains("Nothing was restored"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.historyFile(id).path))
    }
}
