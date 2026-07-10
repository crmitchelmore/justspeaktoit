import Foundation
import XCTest

@testable import SpeakCore

final class HistoryConflictResolverTests: XCTestCase {
    private let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    func testNewerEntryWinsOlderEntry() {
        let older = entry(updatedAt: 10, originDeviceID: "b", text: "older")
        let newer = entry(updatedAt: 20, originDeviceID: "a", text: "newer")

        let merged = HistoryConflictResolver.mergedEntries(existing: [older], incoming: [newer], tombstones: [])

        XCTAssertEqual(merged, [newer])
    }

    func testOlderEntryDoesNotReplaceNewerEntry() {
        let newer = entry(updatedAt: 20, originDeviceID: "a", text: "newer")
        let older = entry(updatedAt: 10, originDeviceID: "z", text: "older")

        let merged = HistoryConflictResolver.mergedEntries(existing: [newer], incoming: [older], tombstones: [])

        XCTAssertEqual(merged, [newer])
    }

    func testEqualTimestampUsesOriginDeviceIDTieBreak() {
        let lower = entry(updatedAt: 10, originDeviceID: "a", text: "lower")
        let higher = entry(updatedAt: 10, originDeviceID: "b", text: "higher")

        let merged = HistoryConflictResolver.mergedEntries(existing: [lower], incoming: [higher], tombstones: [])

        XCTAssertEqual(merged, [higher])
    }

    func testTombstoneWinsEqualTimestamp() {
        let current = entry(updatedAt: 10, originDeviceID: "z", text: "live")
        let tombstone = HistoryDeletionTombstone(
            id: id,
            deletedAt: Date(timeIntervalSince1970: 10),
            originDeviceID: "a"
        )

        let merged = HistoryConflictResolver.mergedEntries(existing: [current], incoming: [], tombstones: [tombstone])

        XCTAssertTrue(merged.isEmpty)
    }

    func testNewerRecreationBeatsOldTombstone() {
        let tombstone = HistoryDeletionTombstone(
            id: id,
            deletedAt: Date(timeIntervalSince1970: 10),
            originDeviceID: "a"
        )
        let recreated = entry(updatedAt: 11, originDeviceID: "b", text: "recreated")

        let merged = HistoryConflictResolver.mergedEntries(existing: [], incoming: [recreated], tombstones: [tombstone])

        XCTAssertEqual(merged, [recreated])
    }

    func testDuplicateReorderedBatchesConverge() {
        let old = entry(updatedAt: 10, originDeviceID: "a", text: "old")
        let new = entry(updatedAt: 20, originDeviceID: "b", text: "new")
        let tombstone = HistoryDeletionTombstone(
            id: UUID(uuidString: "22222222-2222-3333-4444-555555555555")!,
            deletedAt: Date(timeIntervalSince1970: 15),
            originDeviceID: "c"
        )

        let first = HistoryConflictResolver.mergedEntries(
            existing: [old, new],
            incoming: [new, old, old],
            tombstones: [tombstone, tombstone]
        )
        let second = HistoryConflictResolver.mergedEntries(
            existing: [new, old, old],
            incoming: [old, new],
            tombstones: [tombstone]
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.filter { $0.id == id }.count, 1)
        XCTAssertEqual(first.first?.rawTranscription, "new")
    }

    func testBatchAccumulatorAppliesOnlyAfterAllOutOfOrderBatchesArrive() {
        let requestID = UUID()
        let entries = (0..<150).map { index in
            entry(
                id: UUID(),
                updatedAt: TimeInterval(index),
                originDeviceID: "device",
                text: "entry-\(index)"
            )
        }
        let batches = HistorySyncBatchMessage.batches(
            requestID: requestID,
            entries: entries,
            tombstones: []
        )
        var accumulator = HistoryBatchAccumulator()

        XCTAssertNil(accumulator.append(batches[1]))
        let assembled = accumulator.append(batches[0])

        XCTAssertEqual(assembled?.requestID, requestID)
        XCTAssertEqual(assembled?.receivedBatchCount, 2)
        XCTAssertEqual(assembled?.snapshot.entries.count, 150)
    }

    func testBatchAccumulatorIsIdempotentForDuplicateBatch() {
        let requestID = UUID()
        let batch = HistorySyncBatchMessage(
            requestID: requestID,
            batchIndex: 0,
            isLast: true,
            entries: [entry(updatedAt: 1, originDeviceID: "a", text: "one")],
            tombstones: []
        )
        var accumulator = HistoryBatchAccumulator()

        XCTAssertNotNil(accumulator.append(batch))
        XCTAssertNotNil(accumulator.append(batch))
    }

    private func entry(updatedAt: TimeInterval, originDeviceID: String, text: String) -> SyncableHistoryEntry {
        entry(id: id, updatedAt: updatedAt, originDeviceID: originDeviceID, text: text)
    }

    private func entry(
        id: UUID,
        updatedAt: TimeInterval,
        originDeviceID: String,
        text: String
    ) -> SyncableHistoryEntry {
        SyncableHistoryEntry(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1),
            rawTranscription: text,
            postProcessedText: nil,
            model: "model",
            duration: 1,
            wordCount: 1,
            originPlatform: "test",
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            originDeviceID: originDeviceID
        )
    }
}
