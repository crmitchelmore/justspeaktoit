import Foundation
import XCTest

import SpeakCore
import SpeakSync

@testable import SpeakApp

/// FileManager that redirects Application Support to a temporary directory so
/// `HistoryManager` persists to an isolated location during tests.
private final class TemporaryApplicationSupportFileManager: FileManager {
    let supportURL: URL

    init(supportURL: URL) {
        self.supportURL = supportURL
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        guard directory == .applicationSupportDirectory else {
            return super.urls(for: directory, in: domainMask)
        }
        return [supportURL]
    }
}

/// Covers the adapter's bridging contract from #685: local mutations reach the
/// sync engine via the HistoryManager observers, remote changes are applied
/// without echoing back as uploads, and acknowledgements survive a relaunch.
@MainActor
final class MacHistorySyncAdapterTests: XCTestCase {

    private var tempDir: URL!
    private var fileManager: TemporaryApplicationSupportFileManager!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileManager = TemporaryApplicationSupportFileManager(supportURL: tempDir)
        suiteName = "MacHistorySyncAdapterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        fileManager = nil
        try await super.tearDown()
    }

    func testInit_wiresHistoryMutationObservers() async {
        let manager = await makeManager()
        XCTAssertNil(manager.onItemAppended)
        XCTAssertNil(manager.onItemRemoved)

        let adapter = MacHistorySyncAdapter(historyManager: manager, defaults: defaults)

        XCTAssertNotNil(
            manager.onItemAppended,
            "Adapter must observe appends so new items upload without a full sync"
        )
        XCTAssertNotNil(
            manager.onItemRemoved,
            "Adapter must observe removals so remote copies are deleted"
        )
        _ = adapter
    }

    func testRemoteEntry_isStoredAndAcknowledgedWithoutBecomingPending() async {
        let manager = await makeManager()
        let adapter = MacHistorySyncAdapter(historyManager: manager, defaults: defaults)
        let entry = makeEntry(text: "from-another-device")

        await adapter.didReceiveRemoteEntry(entry)

        XCTAssertTrue(
            manager.allItems.contains { $0.id == entry.id },
            "Remote entry must be added to local history"
        )
        XCTAssertFalse(
            adapter.pendingEntries().contains { $0.id == entry.id },
            "A downloaded entry must be acknowledged, not queued for re-upload"
        )
    }

    func testAcknowledgements_persistAcrossAdapterRelaunch() async {
        let manager = await makeManager()
        let item = makeItem()
        await manager.append(item)

        let first = MacHistorySyncAdapter(historyManager: manager, defaults: defaults)
        await first.didAcknowledgeSyncedEntries(ids: [item.id])
        XCTAssertFalse(first.pendingEntries().contains { $0.id == item.id })
        // The write is coalesced; a relaunch after a clean shutdown sees it.
        first.flushPendingSyncedIDs()

        // A fresh adapter over the same defaults simulates app relaunch: the
        // acknowledgement must be durable so the item is not uploaded again.
        let relaunched = MacHistorySyncAdapter(historyManager: manager, defaults: defaults)
        XCTAssertFalse(
            relaunched.pendingEntries().contains { $0.id == item.id },
            "Acknowledged IDs must survive relaunch"
        )
    }

    func testRemoteDeletion_removesLocalItem() async {
        let manager = await makeManager()
        let adapter = MacHistorySyncAdapter(historyManager: manager, defaults: defaults)
        let item = makeItem()
        await manager.append(item)
        await adapter.didAcknowledgeSyncedEntries(ids: [item.id])

        await adapter.didDeleteRemoteEntry(id: item.id)

        XCTAssertFalse(manager.allItems.contains { $0.id == item.id })
        XCTAssertFalse(adapter.pendingEntries().contains { $0.id == item.id })
    }

    // MARK: - Coalesced synced-ID bookkeeping

    /// The sync engine hands a download pass to the delegate one entry at a
    /// time. Each entry used to rewrite the whole synced-ID array to
    /// UserDefaults; the pass must now cost a single write.
    func testRemoteEntryPass_persistsSyncedIDsOnceForTheWholePass() async {
        let manager = await makeManager()
        let counting = WriteCountingUserDefaults(suiteName: suiteName)!
        let adapter = MacHistorySyncAdapter(
            historyManager: manager,
            defaults: counting,
            saveInterval: .seconds(30)
        )
        let entries = (0..<8).map { makeEntry(text: "remote-\($0)") }

        for entry in entries {
            await adapter.didReceiveRemoteEntry(entry)
        }
        let writesDuringPass = counting.writes.total
        adapter.flushPendingSyncedIDs()

        XCTAssertLessThanOrEqual(
            writesDuringPass,
            entries.count / 2,
            "Per-entry bookkeeping writes must be coalesced, not one per entry"
        )
        XCTAssertEqual(
            counting.writes.total,
            1,
            "The whole pass must cost exactly one synced-ID write"
        )
        XCTAssertEqual(
            Set(counting.stringArray(forKey: syncedIDsKey) ?? []),
            Set(entries.map(\.id.uuidString)),
            "Every ID from the pass must be present in the single write"
        )
        for entry in entries {
            XCTAssertTrue(
                manager.allItems.contains { $0.id == entry.id },
                "Every entry in the pass must still be applied locally"
            )
            XCTAssertFalse(
                adapter.pendingEntries().contains { $0.id == entry.id },
                "Coalescing must not make downloaded entries look unsynced"
            )
        }
    }

    /// The coalescing window must close on its own — nothing in the app calls
    /// `flushPendingSyncedIDs()` during a normal sync.
    func testCoalescedSyncedIDs_areWrittenWhenTheWindowElapses() async throws {
        let manager = await makeManager()
        let counting = WriteCountingUserDefaults(suiteName: suiteName)!
        let adapter = MacHistorySyncAdapter(
            historyManager: manager,
            defaults: counting,
            saveInterval: .milliseconds(20)
        )
        let entry = makeEntry(text: "remote")

        await adapter.didReceiveRemoteEntry(entry)

        let deadline = Date().addingTimeInterval(5)
        while counting.writes.total == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(counting.writes.total, 1)
        XCTAssertEqual(counting.stringArray(forKey: syncedIDsKey), [entry.id.uuidString])
    }

    /// A remote record that lost to a newer local item drops its synced ID so
    /// the local edit uploads. That removal must not sit in the coalescing
    /// window: a quit before the window elapses would leave the stale ID on
    /// disk and strand the edit for good (#851).
    func testStaleRemoteEntry_persistsTheSyncedIDRemovalBeforeRelaunch() async {
        let manager = await makeManager()
        let local = makeItem(updatedAt: Date(timeIntervalSince1970: 100))
        await manager.append(local)

        let counting = WriteCountingUserDefaults(suiteName: suiteName)!
        let adapter = MacHistorySyncAdapter(
            historyManager: manager,
            defaults: counting,
            saveInterval: .seconds(30)
        )
        await adapter.didAcknowledgeSyncedEntries(ids: [local.id])
        adapter.flushPendingSyncedIDs()
        XCTAssertFalse(adapter.pendingEntries().contains { $0.id == local.id })

        // The remote copy is older than the local item, so the local one wins
        // and has to be uploaded again.
        let stale = makeEntry(
            id: local.id,
            text: "older-remote",
            updatedAt: Date(timeIntervalSince1970: 50)
        )
        await adapter.didReceiveRemoteEntry(stale)

        XCTAssertFalse(
            adapter.hasPendingSyncedIDWrites,
            "A removal that decides what gets uploaded must be written through, not coalesced"
        )
        XCTAssertEqual(
            counting.stringArray(forKey: syncedIDsKey),
            [],
            "The stale synced ID must already be gone from UserDefaults"
        )
        XCTAssertEqual(
            manager.item(id: local.id)?.rawTranscription,
            local.rawTranscription,
            "The older remote entry must not overwrite the newer local item"
        )

        // No clean shutdown, no elapsed window: a fresh adapter over the same
        // defaults is exactly what the next launch sees.
        let relaunched = MacHistorySyncAdapter(historyManager: manager, defaults: counting)
        XCTAssertTrue(
            relaunched.pendingEntries().contains { $0.id == local.id },
            "The locally newer item must be pending upload after relaunch"
        )
    }

    /// Termination calls `flushPendingSyncedIDs()`; everything the window was
    /// still holding has to reach UserDefaults in that one call.
    func testFlushPendingSyncedIDs_persistsEverythingTheWindowWasHolding() async {
        let manager = await makeManager()
        let counting = WriteCountingUserDefaults(suiteName: suiteName)!
        let adapter = MacHistorySyncAdapter(
            historyManager: manager,
            defaults: counting,
            saveInterval: .seconds(30)
        )
        let acknowledged = (0..<3).map { _ in UUID() }
        let remote = makeEntry(text: "remote")
        await adapter.didAcknowledgeSyncedEntries(ids: Set(acknowledged))
        await adapter.didReceiveRemoteEntry(remote)
        XCTAssertTrue(adapter.hasPendingSyncedIDWrites)
        XCTAssertNil(counting.stringArray(forKey: syncedIDsKey))

        adapter.flushPendingSyncedIDs()

        XCTAssertFalse(adapter.hasPendingSyncedIDWrites)
        XCTAssertEqual(
            Set(counting.stringArray(forKey: syncedIDsKey) ?? []),
            Set((acknowledged + [remote.id]).map(\.uuidString)),
            "The flush must persist every ID the window was still holding"
        )
        XCTAssertEqual(counting.writes.total, 1, "The flush must cost a single write")

        adapter.flushPendingSyncedIDs()
        XCTAssertEqual(counting.writes.total, 1, "A flush with nothing pending must not write")
    }

    /// A coalescing task that is already past its sleep when a later change
    /// supersedes it still runs. It must not write, and above all must not
    /// clear the replacement window's task handle and dirty flag, or the
    /// replacement escapes `flushPendingSyncedIDs()` entirely (#870).
    func testSupersededWindow_doesNotWriteOrClearItsReplacement() async throws {
        let manager = await makeManager()
        let counting = WriteCountingUserDefaults(suiteName: suiteName)!
        let adapter = MacHistorySyncAdapter(
            historyManager: manager,
            defaults: counting,
            saveInterval: .milliseconds(50)
        )
        let first = UUID()
        let second = UUID()

        await adapter.didAcknowledgeSyncedEntries(ids: [first])
        // Let the first window's task actually start and reach its sleep, then
        // block the main actor so the sleep elapses while its flush stays
        // queued behind us — the exact interleaving from #870.
        await Task.yield()
        Thread.sleep(forTimeInterval: 0.15)
        await adapter.didAcknowledgeSyncedEntries(ids: [second])
        // Long enough to drain the superseded flush, short of the new window.
        try await Task.sleep(for: .milliseconds(5))

        XCTAssertEqual(
            counting.writes.total,
            0,
            "A superseded window must not write; its replacement owns the write"
        )
        XCTAssertTrue(
            adapter.hasPendingSyncedIDWrites,
            "A superseded window must leave the replacement's dirty flag alone"
        )

        adapter.flushPendingSyncedIDs()

        XCTAssertFalse(adapter.hasPendingSyncedIDWrites)
        XCTAssertEqual(
            Set(counting.stringArray(forKey: syncedIDsKey) ?? []),
            Set([first, second].map(\.uuidString)),
            "The flush must persist both windows' IDs"
        )
        XCTAssertEqual(counting.writes.total, 1, "The whole sequence must cost one write")

        // The outstanding task must have been cancelled by the flush, not left
        // running to write again once its window elapses.
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(counting.writes.total, 1, "The flush must cancel the outstanding window")
    }

    // MARK: - Helpers

    private let syncedIDsKey = "speak.sync.syncedMacHistoryIDs"

    private func makeManager() async -> HistoryManager {
        let manager = HistoryManager(
            fileManager: fileManager,
            flushInterval: 3600,
            batchSizeThreshold: 10_000
        )
        await manager.waitUntilLoaded()
        return manager
    }
}

// MARK: - Fixtures

private func makeItem(id: UUID = UUID(), updatedAt: Date = Date()) -> HistoryItem {
    HistoryItem(
        id: id,
        createdAt: Date(),
        updatedAt: updatedAt,
        modelsUsed: ["apple/local/SFSpeechRecognizer"],
        rawTranscription: "raw transcript",
        postProcessedTranscription: nil,
        recordingDuration: 5,
        cost: nil,
        audioFileURL: nil,
        networkExchanges: [],
        events: [],
        phaseTimestamps: PhaseTimestamps(
            recordingStarted: nil,
            recordingEnded: nil,
            transcriptionStarted: nil,
            transcriptionEnded: nil,
            postProcessingStarted: nil,
            postProcessingEnded: nil,
            outputDelivered: nil
        ),
        trigger: HistoryTrigger(
            gesture: .singleTap,
            hotKeyDescription: "Fn",
            outputMethod: .clipboard,
            destinationApplication: nil
        ),
        personalCorrections: nil,
        errors: []
    )
}
