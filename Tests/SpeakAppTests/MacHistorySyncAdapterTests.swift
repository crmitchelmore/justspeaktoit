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

/// Thread-safe counter shared with a `UserDefaults` subclass, which must stay
/// `Sendable` and therefore cannot hold mutable state of its own.
private final class WriteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

/// UserDefaults that counts writes, so the tests can assert how many times the
/// synced-ID bookkeeping array is rewritten during a sync pass.
private final class WriteCountingUserDefaults: UserDefaults {
    let writes = WriteCounter()

    override func set(_ value: Any?, forKey defaultName: String) {
        writes.increment()
        super.set(value, forKey: defaultName)
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

    private func makeEntry(id: UUID = UUID(), text: String) -> SyncableHistoryEntry {
        SyncableHistoryEntry(
            id: id,
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

    private func makeItem(id: UUID = UUID()) -> HistoryItem {
        HistoryItem(
            id: id,
            createdAt: Date(),
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
}
