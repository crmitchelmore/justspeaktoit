#if os(iOS)
import Foundation
import XCTest
import SpeakCore

@testable import SpeakiOSLib

/// Regression coverage for the background Action Button history-loss bug: a
/// freshly created manager (as happens when a headless intent touches `.shared`
/// cold) must load existing history *before* the first append, so recording
/// never wipes prior entries.
@MainActor
final class HistoryManagerPersistenceTests: XCTestCase {

    private var tempDir: URL!
    private var fileURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("transcription-history.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        fileURL = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func writeHistory(_ items: [iOSHistoryItem]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(items).write(to: fileURL, options: .atomic)
    }

    private func readHistory() throws -> [iOSHistoryItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([iOSHistoryItem].self, from: Data(contentsOf: fileURL))
    }

    private func makeItem(_ text: String) -> iOSHistoryItem {
        iOSHistoryItem(
            transcription: text,
            model: "apple/local/SFSpeechRecognizer",
            duration: 3,
            wordCount: text.split(separator: " ").count
        )
    }

    // MARK: - Tests

    func testColdManagerLoadsExistingHistoryImmediately() throws {
        // Arrange: a prior recording already on disk.
        try writeHistory([makeItem("hello there")])

        // Act: create a cold manager (as a background intent would).
        let manager = iOSHistoryManager(fileURL: fileURL, syncEnabled: false)

        // Assert: the existing entry is visible right away, no async wait.
        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.items.first?.transcription, "hello there")
    }

    func testRecordingFromColdManagerPreservesExistingHistory() throws {
        // Arrange: three prior recordings on disk.
        let prior = (0..<3).map { makeItem("prior \($0)") }
        try writeHistory(prior)

        // Act: a cold manager records a new transcription.
        let manager = iOSHistoryManager(fileURL: fileURL, syncEnabled: false)
        manager.recordTranscription(
            text: "brand new",
            model: "apple/local/SFSpeechRecognizer",
            duration: 2
        )

        // Assert: all four survive both in memory and on disk (newest first).
        XCTAssertEqual(manager.items.count, 4)
        XCTAssertEqual(manager.items.first?.transcription, "brand new")

        let onDisk = try readHistory()
        XCTAssertEqual(onDisk.count, 4)
        XCTAssertTrue(onDisk.contains { $0.transcription == "prior 0" })
        XCTAssertTrue(onDisk.contains { $0.transcription == "brand new" })
    }

    func testRemoveFromColdManagerDoesNotClobberOtherEntries() throws {
        // Arrange: three prior recordings on disk.
        let prior = (0..<3).map { makeItem("p\($0)") }
        try writeHistory(prior)

        // Act: a cold manager removes one entry.
        let manager = iOSHistoryManager(fileURL: fileURL, syncEnabled: false)
        manager.remove(prior[1])

        // Assert: only the targeted entry is gone; the rest are retained.
        let onDisk = try readHistory()
        XCTAssertEqual(onDisk.count, 2)
        XCTAssertFalse(onDisk.contains { $0.id == prior[1].id })
    }

    func testEmptyDiskRecordingPersistsSingleEntry() throws {
        // Arrange: no file on disk yet.
        let manager = iOSHistoryManager(fileURL: fileURL, syncEnabled: false)

        // Act.
        manager.recordTranscription(
            text: "first ever",
            model: "apple/local/SFSpeechRecognizer",
            duration: 1
        )

        // Assert.
        XCTAssertEqual(try readHistory().count, 1)
    }

    func testRemoteApplyUpdatesExistingEntryByLWW() async throws {
        let id = UUID()
        let manager = iOSHistoryManager(fileURL: fileURL, syncEnabled: false)
        manager.add(
            iOSHistoryItem(
                id: id,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2),
                transcription: "old",
                model: "m",
                duration: 1,
                wordCount: 1,
                originDeviceID: "a"
            )
        )
        let remote = SyncableHistoryEntry(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1),
            rawTranscription: "new",
            postProcessedText: nil,
            model: "m",
            duration: 1,
            wordCount: 1,
            originPlatform: "ios",
            updatedAt: Date(timeIntervalSince1970: 3),
            originDeviceID: "b"
        )

        await manager.applyHistoryBatch(entries: [remote], tombstones: [])

        XCTAssertEqual(manager.items.count, 1)
        XCTAssertEqual(manager.items.first?.transcription, "new")
        XCTAssertEqual(try readHistory().count, 1)
    }

    func testRemoteDuplicateAndReorderedDeleteConvergesWithoutResurrection() async throws {
        let id = UUID()
        let manager = iOSHistoryManager(fileURL: fileURL, syncEnabled: false)
        let live = SyncableHistoryEntry(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1),
            rawTranscription: "live",
            postProcessedText: nil,
            model: "m",
            duration: 1,
            wordCount: 1,
            originPlatform: "ios",
            updatedAt: Date(timeIntervalSince1970: 2),
            originDeviceID: "a"
        )
        let tombstone = HistoryDeletionTombstone(
            id: id,
            deletedAt: Date(timeIntervalSince1970: 2),
            originDeviceID: "b"
        )

        await manager.applyHistoryBatch(entries: [live, live], tombstones: [])
        await manager.applyHistoryBatch(entries: [], tombstones: [tombstone, tombstone])
        await manager.applyHistoryBatch(entries: [live], tombstones: [])

        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertTrue(try readHistory().isEmpty)
    }

    func testOlderCloudEntryDoesNotMarkNewerLocalRevisionAsSynced() {
        let id = UUID()
        let manager = iOSHistoryManager(fileURL: fileURL, syncEnabled: false)
        manager.add(
            iOSHistoryItem(
                id: id,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 3),
                transcription: "newer local",
                model: "m",
                duration: 1,
                wordCount: 2,
                originDeviceID: "z"
            )
        )
        let olderCloudEntry = SyncableHistoryEntry(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1),
            rawTranscription: "older cloud",
            postProcessedText: nil,
            model: "m",
            duration: 1,
            wordCount: 2,
            originPlatform: "ios",
            updatedAt: Date(timeIntervalSince1970: 2),
            originDeviceID: "a"
        )

        manager.didReceiveRemoteEntry(olderCloudEntry)

        XCTAssertEqual(manager.items.first?.transcription, "newer local")
        XCTAssertFalse(manager.syncedIDs.contains(id))
    }
}
#endif
