#if os(iOS)
import Foundation
import XCTest
@testable import SpeakiOSLib
@testable import SpeakSync

@MainActor
final class HistoryRecoveryReviewTests: XCTestCase {
    private var directory: URL!
    private var file: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("history.json")
        suite = UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    private func item(_ text: String, id: UUID = UUID(), date: TimeInterval = 10) -> iOSHistoryItem {
        iOSHistoryItem(id: id, createdAt: Date(timeIntervalSince1970: date),
                       transcription: text, model: "test", duration: 1, wordCount: 1)
    }

    private func write(_ items: [iOSHistoryItem], to url: URL? = nil) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(items).write(to: url ?? file)
    }

    private func manager(_ storageIO: IOSHistoryPersistence.StorageIO = .init()) -> iOSHistoryManager {
        iOSHistoryManager(fileURL: file, syncEnabled: false, userDefaults: defaults, storageIO: storageIO)
    }

    func testLegacySidecarCannotRollBackEquallyDatedCommittedPrimary() throws {
        let old = item("old", date: 10.1)
        let committed = item("committed", id: old.id, date: 10.8)
        try write([committed])
        try write([old], to: file.appendingPathExtension("recovery"))
        XCTAssertEqual(manager().items.first?.transcription, "committed")
        XCTAssertEqual(manager().items.first?.transcription, "committed")
    }

    func testPendingSameSecondUpdateSurvivesUnrelatedPrimaryChangeAndRelaunch() throws {
        let old = item("old", date: 10.1)
        let pending = item("pending", id: old.id, date: 10.8)
        let unrelated = item("unrelated")
        try write([old])
        let primary = try XCTUnwrap(file)
        var storageIO = IOSHistoryPersistence.StorageIO()
        storageIO.write = { data, url in
            if url == primary { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        let history = manager(storageIO)
        XCTAssertTrue(history.upsertReportingDurability(pending))
        try write([old, unrelated])
        let relaunched = manager()
        XCTAssertEqual(relaunched.items.first { $0.id == old.id }?.transcription, "pending")
        XCTAssertEqual(Set(relaunched.items.map(\.id)), [old.id, unrelated.id])
    }

    func testCleanupFailureRetainedSidecarCannotUndoLaterSameSecondCommit() throws {
        let old = item("old", date: 10.1)
        let pending = item("pending", id: old.id, date: 10.2)
        let committed = item("committed", id: old.id, date: 10.8)
        try write([old])
        let primary = try XCTUnwrap(file)
        var blockPrimary = true
        var storageIO = IOSHistoryPersistence.StorageIO()
        storageIO.write = { data, url in
            if url == primary && blockPrimary { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        storageIO.remove = { _ in throw CocoaError(.fileWriteNoPermission) }
        let history = manager(storageIO)
        XCTAssertTrue(history.upsertReportingDurability(pending))
        blockPrimary = false
        XCTAssertTrue(history.upsertReportingDurability(committed))
        XCTAssertFalse(history.isStorageReady)
        XCTAssertEqual(manager().items.first?.transcription, "committed")
    }

    func testFreshPendingEditSupersedesStaleSidecarBaseAfterRelaunch() throws {
        let old = item("old", date: 10.1)
        let stale = item("stale", id: old.id, date: 10.2)
        let committed = item("committed", id: old.id, date: 10.5)
        let fresh = item("fresh", id: old.id, date: 10.8)
        try write([old])
        let primary = try XCTUnwrap(file)
        var storageIO = IOSHistoryPersistence.StorageIO()
        storageIO.write = { data, url in
            if url == primary { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        XCTAssertTrue(manager(storageIO).upsertReportingDurability(stale))
        try write([committed])
        let relaunched = manager(storageIO)
        XCTAssertEqual(relaunched.items.first?.transcription, "committed")
        XCTAssertTrue(relaunched.upsertReportingDurability(fresh))
        XCTAssertEqual(manager().items.first?.transcription, "fresh")
    }

    func testRetainedTombstoneCannotDeleteRecreatedPrimaryAfterCleanupFailure() async throws {
        let old = item("old")
        try write([old])
        let primary = try XCTUnwrap(file)
        var blockPrimary = true
        var storageIO = IOSHistoryPersistence.StorageIO()
        storageIO.write = { data, url in
            if url == primary && blockPrimary { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        storageIO.remove = { _ in throw CocoaError(.fileWriteNoPermission) }
        let history = manager(storageIO)
        await history.didDeleteRemoteEntry(id: old.id)
        blockPrimary = false
        history.retryPersistence()
        let recreated = item("recreated", id: old.id, date: 20)
        XCTAssertTrue(history.upsertReportingDurability(recreated))
        XCTAssertFalse(history.isStorageReady)
        XCTAssertEqual(manager().items.map(\.transcription), ["recreated"])
    }

    func testUpsertKeepsOrderAndNewestVersionWithoutResortingExistingRows() throws {
        let old = item("old", date: 10)
        let latest = item("latest", date: 30)
        try write([latest, old])
        let history = manager()
        let middle = item("middle", date: 20)
        history.add(middle)
        history.add(item("stale", id: latest.id, date: 1))
        XCTAssertEqual(history.items.map(\.transcription), ["latest", "middle", "old"])
        history.add(item("moved", id: old.id, date: 40))
        XCTAssertEqual(history.items.map(\.transcription), ["moved", "latest", "middle"])
    }

    func testRepeatedUpsertsDuringOutageWaitForExplicitRetryBeforeReloading() throws {
        let primary = try XCTUnwrap(file)
        var reads = 0
        var storageIO = IOSHistoryPersistence.StorageIO()
        storageIO.read = { url in
            if url == primary {
                reads += 1
                throw CocoaError(.fileReadNoPermission)
            }
            return try Data(contentsOf: url)
        }
        let history = manager(storageIO)
        for index in 0..<3 { XCTAssertTrue(history.upsertReportingDurability(item("pending \(index)"))) }
        XCTAssertEqual(reads, 1)
        history.retryPersistence()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(history.items.count, 3)
    }

    func testFailedRemoteUpdateAndDeletionRecoverFromSidecarAfterRelaunch() async throws {
        let old = item("old")
        let deleted = item("deleted")
        let remote = item("remote", id: old.id, date: 20)
        try write([old, deleted])
        defaults.set([old.id.uuidString, deleted.id.uuidString], forKey: iOSHistoryManager.syncedIDsKey)
        let primary = try XCTUnwrap(file)
        var storageIO = IOSHistoryPersistence.StorageIO()
        storageIO.write = { data, url in
            if url == primary { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        let history = manager(storageIO)
        await history.didReceiveRemoteEntry(remote.toSyncable())
        await history.didDeleteRemoteEntry(id: deleted.id)
        try await history.persistRemoteChanges()
        let relaunched = manager()
        XCTAssertEqual(relaunched.items.map(\.id), [old.id])
        XCTAssertEqual(relaunched.items.first?.transcription, "remote")
        XCTAssertFalse(relaunched.pendingEntries().contains { $0.id == deleted.id })
    }

    func testFailedBothStoresKeepsTokenAndAcknowledgementsForRelaunchReplay() async throws {
        let old = item("old")
        let deleted = item("deleted")
        let remote = item("remote", id: old.id, date: 20)
        try write([old, deleted])
        defaults.set([old.id.uuidString, deleted.id.uuidString], forKey: iOSHistoryManager.syncedIDsKey)
        let oldToken = Data("old token".utf8)
        let newToken = Data("new token".utf8)
        defaults.set(oldToken, forKey: SyncConfiguration.syncTokenKey)
        var storageIO = IOSHistoryPersistence.StorageIO()
        storageIO.write = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        let page = HistoryChangePage(changes: [.changed(remote.toSyncable()), .deleted(deleted.id)],
                                     serverChangeTokenData: newToken, moreComing: false)
        let history = manager(storageIO)
        let transport = RecoveryTestTransport(page: page)
        let engine = HistorySyncEngine(
            transport: transport, defaults: defaults, cloudAvailable: true, delegate: history)
        await engine.sync()
        XCTAssertNotNil(engine.state.error)
        XCTAssertEqual(defaults.data(forKey: SyncConfiguration.syncTokenKey), oldToken)
        XCTAssertEqual(Set(defaults.stringArray(forKey: iOSHistoryManager.syncedIDsKey) ?? []),
                       [old.id.uuidString, deleted.id.uuidString])
        XCTAssertTrue(transport.uploadedIDs.isEmpty)

        let relaunched = manager()
        let retryTransport = RecoveryTestTransport(page: page)
        let retryEngine = HistorySyncEngine(transport: retryTransport, defaults: defaults,
                                           cloudAvailable: true, delegate: relaunched)
        await retryEngine.sync()
        XCTAssertNil(retryEngine.state.error)
        XCTAssertEqual(retryTransport.tokens, [oldToken])
        XCTAssertEqual(defaults.data(forKey: SyncConfiguration.syncTokenKey), newToken)
        XCTAssertEqual(manager().items.map(\.transcription), ["remote"])
        XCTAssertFalse(retryTransport.uploadedIDs.contains(deleted.id))
    }
}

@MainActor
private final class RecoveryTestTransport: HistorySyncTransport {
    let page: HistoryChangePage
    var tokens: [Data?] = []
    var uploadedIDs: Set<UUID> = []

    init(page: HistoryChangePage) { self.page = page }

    func fetchChanges(after tokenData: Data?) async throws -> HistoryChangePage {
        tokens.append(tokenData)
        return page
    }

    func upload(entries: [SyncableHistoryEntry]) async -> HistoryUploadResult {
        let ids = Set(entries.map(\.id))
        uploadedIDs.formUnion(ids)
        return .success(ids: ids)
    }

    func delete(entryID: UUID) async throws {}
}
#endif
