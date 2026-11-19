import CloudKit
import Foundation
import XCTest

@testable import SpeakSync

/// The one-time History copy from the legacy CloudKit container (#1119).
@MainActor
final class HistoryLegacyContainerMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "HistoryLegacyContainerMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    func testMigration_pushesEveryLegacyEntryOnceThroughTheUploadPath() async {
        let kept = makeEntry(text: "kept")
        let deleted = makeEntry(text: "deleted")
        let legacy = LegacyTransport(pages: [
            [.changed(kept), .changed(deleted)],
            [.deleted(deleted.id)]
        ])
        let shared = RecordingTransport()
        let delegate = AckingDelegate(entries: [])
        let engine = HistorySyncEngine(transport: shared, defaults: defaults, cloudAvailable: true, delegate: delegate)

        let migrated = await engine.migrateHistory(from: legacy)
        XCTAssertTrue(migrated)

        XCTAssertEqual(legacy.requestedTokens, [nil, Data("page-1".utf8)])
        XCTAssertEqual(shared.uploadedBatches, [[kept.id]])
        XCTAssertEqual(delegate.acknowledgedIDs, [kept.id])
        XCTAssertTrue(defaults.bool(forKey: SyncContainerTransition.historyMigrationCompletedKey))

        let rerun = await engine.migrateHistory(from: legacy)
        XCTAssertTrue(rerun)
        XCTAssertEqual(legacy.requestedTokens.count, 2, "a finished copy never reads the legacy container again")
    }

    func testFailedRead_leavesTheCopyPendingForTheNextLaunch() async {
        let legacy = LegacyTransport(pages: [])
        legacy.error = CKError(.networkFailure)
        let shared = RecordingTransport()
        let engine = HistorySyncEngine(
            transport: shared, defaults: defaults, cloudAvailable: true, delegate: AckingDelegate(entries: [])
        )

        let migrated = await engine.migrateHistory(from: legacy)
        XCTAssertFalse(migrated)
        XCTAssertFalse(defaults.bool(forKey: SyncContainerTransition.historyMigrationCompletedKey))
        XCTAssertEqual(shared.uploadedBatches, [])
    }

    func testMissingLegacyZone_completesWithNothingToCopy() async {
        let legacy = LegacyTransport(pages: [])
        legacy.error = CKError(.zoneNotFound)
        let engine = HistorySyncEngine(
            transport: RecordingTransport(), defaults: defaults, cloudAvailable: true,
            delegate: AckingDelegate(entries: [])
        )

        let migrated = await engine.migrateHistory(from: legacy)
        XCTAssertTrue(migrated)
        XCTAssertTrue(defaults.bool(forKey: SyncContainerTransition.historyMigrationCompletedKey))
    }

    func testSyncSwitchedOff_copiesNothingAndStaysPending() async {
        defaults.set(false, forKey: SyncConfiguration.dataSyncEnabledKey)
        let legacy = LegacyTransport(pages: [[.changed(makeEntry(text: "private"))]])
        let engine = HistorySyncEngine(
            transport: RecordingTransport(), defaults: defaults, cloudAvailable: true,
            delegate: AckingDelegate(entries: [])
        )

        let migrated = await engine.migrateHistory(from: legacy)
        XCTAssertFalse(migrated)
        XCTAssertEqual(legacy.requestedTokens, [])
        XCTAssertFalse(defaults.bool(forKey: SyncContainerTransition.historyMigrationCompletedKey))
    }

    private func makeEntry(text: String) -> SyncableHistoryEntry {
        SyncableHistoryEntry(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1),
            rawTranscription: text,
            postProcessedText: nil,
            model: "test",
            duration: 1,
            wordCount: 1,
            originPlatform: "ios",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
    }
}

@MainActor
private final class LegacyTransport: HistorySyncTransport {
    private let pages: [[HistoryRemoteChange]]
    private(set) var requestedTokens: [Data?] = []
    var error: Error?

    init(pages: [[HistoryRemoteChange]]) {
        self.pages = pages
    }

    func fetchChanges(after tokenData: Data?) async throws -> HistoryChangePage {
        if let error { throw error }
        requestedTokens.append(tokenData)
        let index = requestedTokens.count - 1
        return HistoryChangePage(
            changes: pages[index],
            serverChangeTokenData: Data("page-\(index + 1)".utf8),
            moreComing: index + 1 < pages.count
        )
    }

    func upload(entries _: [SyncableHistoryEntry]) async -> HistoryUploadResult {
        XCTFail("The legacy container is never written")
        return HistoryUploadResult(acknowledgedIDs: [], remoteEntries: [], failures: [:])
    }

    func delete(entryID _: UUID) async throws {
        XCTFail("The legacy container is never written")
    }
}
