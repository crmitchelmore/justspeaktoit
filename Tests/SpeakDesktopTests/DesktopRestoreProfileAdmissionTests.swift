import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop

final class DesktopRestoreProfileAdmissionTests: XCTestCase {
    func testProfileSaveAtWriteBoundaryIsPreservedAndRestoreIsRejected() async throws {
        try await assertSaveAtProfileBoundary(changesHistory: false)
    }

    func testProfileAndHistorySavesAtWriteBoundaryAreBothPreserved() async throws {
        try await assertSaveAtProfileBoundary(changesHistory: true)
    }

    private func assertSaveAtProfileBoundary(changesHistory: Bool) async throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        let original = DictationProfile(name: "Original", polishPrompt: nil)
        let newer = DictationProfile(name: "Newer saved edit", polishPrompt: nil)
        try fixture.profiles.save([original])
        let id = UUID()
        try await fixture.store.save(RestoreFixture.native(id, text: nil))
        let historyBefore = try Data(contentsOf: fixture.historyFile(id))
        let historyAfter = try JSONEncoder().encode(RestoreFixture.native(id, text: "Newer recording"))
        let plan = try await DesktopMigrationRestore.plan(RestoreFixture.snapshot([
            .history: [try RestoreFixture.history(id, text: "Backup")],
            .profiles: [try RestoreFixture.profile(DictationProfile(name: "Incoming", polishPrompt: nil))]
        ]), targets: fixture.targets)
        let profiles = fixture.profiles
        let historyURL = fixture.historyFile(id)
        let outcome = await DesktopMigrationRestore.apply(
            plan, choice: .replace, targets: fixture.targets,
            checkpoint: { step in
                if step == .profiles {
                    try profiles.save([newer])
                    if changesHistory { try historyAfter.write(to: historyURL, options: .atomic) }
                }
            }
        )
        guard case .stale = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try fixture.profiles.load(), [newer])
        XCTAssertEqual(try Data(contentsOf: historyURL), changesHistory ? historyAfter : historyBefore)
    }

    func testRollbackDoesNotOverwriteProfileSaveAfterRestoreWrite() async throws {
        try await assertSaveAfterRestoreWrite(throwsHistoryFailure: true)
    }

    func testProfileSaveAfterRestoreWriteRejectsHistoryCommitWithoutAnotherFailure() async throws {
        try await assertSaveAfterRestoreWrite(throwsHistoryFailure: false)
    }

    private func assertSaveAfterRestoreWrite(throwsHistoryFailure: Bool) async throws {
        let fixture = try RestoreFixture()
        defer { fixture.remove() }
        try fixture.profiles.save([DictationProfile(name: "Original", polishPrompt: nil)])
        let newer = DictationProfile(name: "Newer saved edit", polishPrompt: nil)
        let id = UUID()
        let plan = try await DesktopMigrationRestore.plan(RestoreFixture.snapshot([
            .history: [try RestoreFixture.history(id, text: "Backup")],
            .profiles: [try RestoreFixture.profile(DictationProfile(name: "Incoming", polishPrompt: nil))]
        ]), targets: fixture.targets)
        let profiles = fixture.profiles
        let outcome = await DesktopMigrationRestore.apply(
            plan, choice: .replace, targets: fixture.targets,
            checkpoint: { step in
                if step == .history(0) {
                    try profiles.save([newer])
                    if throwsHistoryFailure { throw DesktopMigrationRestore.StaleHistory() }
                }
            }
        )
        guard case let .failed(restored, message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(restored)
        XCTAssertTrue(message.contains("newer profiles were preserved"))
        XCTAssertFalse(message.contains("Nothing was restored"))
        XCTAssertEqual(try fixture.profiles.load(), [newer])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.historyFile(id).path))
    }
}
