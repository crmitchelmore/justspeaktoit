#if os(iOS)
import Foundation
import SpeakSync
import XCTest

@testable import SpeakiOSLib

@MainActor
final class HistorySyncReconciliationTests: XCTestCase {
    private var tempDirectory: URL!
    private var fileURL: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        fileURL = tempDirectory.appendingPathComponent("transcription-history.json")
        suiteName = "HistorySyncReconciliationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testLegacyAcknowledgementsArePrunedToCurrentLocalIDsAndCountsStayValid() throws {
        let localItems = (0..<19).map { makeItem(text: "local \($0)") }
        try writeHistory(localItems)
        let acknowledgedLocalIDs = Set(localItems.prefix(5).map(\.id))
        let staleIDs = Set((0..<39).map { _ in UUID() })
        defaults.set(
            acknowledgedLocalIDs.union(staleIDs).map(\.uuidString),
            forKey: iOSHistoryManager.syncedIDsKey
        )

        let manager = makeManager()

        XCTAssertEqual(manager.items.count, 19)
        XCTAssertEqual(manager.syncedCount, 5)
        XCTAssertEqual(manager.unsyncedCount, 14)
        XCTAssertGreaterThanOrEqual(manager.syncedCount, 0)
        XCTAssertLessThanOrEqual(manager.syncedCount, manager.items.count)
        XCTAssertEqual(manager.unsyncedCount, manager.items.count - manager.syncedCount)
        XCTAssertEqual(persistedAcknowledgedIDs(), acknowledgedLocalIDs)
    }

    func testLocalDeletePrunesAcknowledgementImmediately() async throws {
        let item = makeItem(text: "delete")
        try writeHistory([item])
        let manager = makeManager()
        await manager.didAcknowledgeSyncedEntries(ids: [item.id])
        XCTAssertEqual(manager.syncedCount, 1)

        manager.remove(item)

        XCTAssertEqual(manager.items.count, 0)
        XCTAssertEqual(manager.syncedCount, 0)
        XCTAssertEqual(manager.unsyncedCount, 0)
        XCTAssertTrue(persistedAcknowledgedIDs().isEmpty)
    }

    func testAlreadyPresentRemoteDuplicateBecomesAcknowledgedWithoutDuplication() async throws {
        let item = makeItem(text: "same")
        try writeHistory([item])
        let manager = makeManager()

        await manager.didReceiveRemoteEntry(item.toSyncable())

        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.syncedCount, 1)
        XCTAssertEqual(manager.unsyncedCount, 0)
    }

    func testNewerRemoteUpdateReplacesLocalUsingUpdatedAt() async throws {
        let local = makeItem(
            text: "old",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        try writeHistory([local])
        let manager = makeManager()
        let remote = makeEntry(
            id: local.id,
            text: "new",
            createdAt: local.createdAt,
            updatedAt: Date(timeIntervalSince1970: 30)
        )

        await manager.didReceiveRemoteEntry(remote)

        XCTAssertEqual(manager.items.first?.transcription, "new")
        XCTAssertEqual(manager.items.first?.updatedAt, remote.updatedAt)
        XCTAssertEqual(manager.syncedCount, 1)
    }

    func testOlderRemoteUpdateLeavesNewerLocalEntryPending() async throws {
        let local = makeItem(
            text: "local-newer",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        try writeHistory([local])
        defaults.set([local.id.uuidString], forKey: iOSHistoryManager.syncedIDsKey)
        let manager = makeManager()
        let remote = makeEntry(
            id: local.id,
            text: "remote-older",
            createdAt: local.createdAt,
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        await manager.didReceiveRemoteEntry(remote)

        XCTAssertEqual(manager.items.first?.transcription, "local-newer")
        XCTAssertEqual(manager.syncedCount, 0)
        XCTAssertEqual(manager.unsyncedCount, 1)
    }

    func testRemoteTombstoneRemovesItemAndAcknowledgement() async throws {
        let item = makeItem(text: "remote delete")
        try writeHistory([item])
        defaults.set([item.id.uuidString], forKey: iOSHistoryManager.syncedIDsKey)
        let manager = makeManager()

        await manager.didDeleteRemoteEntry(id: item.id)

        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertEqual(manager.syncedCount, 0)
        XCTAssertEqual(manager.unsyncedCount, 0)
        XCTAssertTrue(persistedAcknowledgedIDs().isEmpty)
    }

    func testProgressFractionClampsLegacyOrCorruptCounts() {
        XCTAssertEqual(HistorySyncProgress.fraction(syncedCount: 44, totalCount: 19), 1)
        XCTAssertEqual(HistorySyncProgress.fraction(syncedCount: -1, totalCount: 19), 0)
        XCTAssertEqual(HistorySyncProgress.fraction(syncedCount: 5, totalCount: 20), 0.25)
        XCTAssertEqual(HistorySyncProgress.fraction(syncedCount: 5, totalCount: 0), 0)
    }

    private func makeManager() -> iOSHistoryManager {
        iOSHistoryManager(fileURL: fileURL, syncEnabled: false, userDefaults: defaults)
    }

    private func writeHistory(_ items: [iOSHistoryItem]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(items).write(to: fileURL, options: .atomic)
    }

    private func persistedAcknowledgedIDs() -> Set<UUID> {
        Set(
            (defaults.stringArray(forKey: iOSHistoryManager.syncedIDsKey) ?? [])
                .compactMap(UUID.init(uuidString:))
        )
    }

    private func makeItem(
        text: String,
        createdAt: Date = Date(timeIntervalSince1970: 10),
        updatedAt: Date = Date(timeIntervalSince1970: 10)
    ) -> iOSHistoryItem {
        iOSHistoryItem(
            createdAt: createdAt,
            updatedAt: updatedAt,
            transcription: text,
            model: "test",
            duration: 1,
            wordCount: 1
        )
    }

    private func makeEntry(
        id: UUID,
        text: String,
        createdAt: Date,
        updatedAt: Date
    ) -> SyncableHistoryEntry {
        SyncableHistoryEntry(
            id: id,
            createdAt: createdAt,
            rawTranscription: text,
            postProcessedText: nil,
            model: "test",
            duration: 1,
            wordCount: 1,
            originPlatform: "ios",
            updatedAt: updatedAt
        )
    }
}
#endif
