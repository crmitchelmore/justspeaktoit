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

    // MARK: - Helpers

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
