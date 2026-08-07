import Foundation
import XCTest

@testable import SpeakSync

/// Order-based coalescing that makes CloudKit change pages deterministic:
/// exactly one final event per record ID, in arrival order of those final events.
final class HistorySyncReconcilerTests: XCTestCase {
    func testEmptyInput_yieldsEmptyOutput() {
        XCTAssertTrue(HistoryChangeReconciler.coalesced([]).isEmpty)
    }

    func testChangeThenTombstone_keepsOnlyTombstone() {
        let id = UUID()
        let result = HistoryChangeReconciler.coalesced([
            .changed(makeEntry(id: id, text: "alive")),
            .deleted(id)
        ])
        XCTAssertEqual(result.count, 1)
        guard case .deleted(let deletedID) = result[0] else {
            XCTFail("Expected tombstone to win"); return
        }
        XCTAssertEqual(deletedID, id)
    }

    func testTombstoneThenChange_keepsOnlyResurrectedEntry() {
        let id = UUID()
        let result = HistoryChangeReconciler.coalesced([
            .deleted(id),
            .changed(makeEntry(id: id, text: "resurrected"))
        ])
        XCTAssertEqual(result.count, 1)
        guard case .changed(let entry) = result[0] else {
            XCTFail("Expected change to win"); return
        }
        XCTAssertEqual(entry.rawTranscription, "resurrected")
    }

    func testDuplicateIDs_lastEventWinsRegardlessOfEmbeddedTimestamps() {
        // CloudKit page order is the authority: a later event wins even when
        // its payload carries an older updatedAt (device clock skew must not
        // reorder the server's change feed).
        let id = UUID()
        let newerTimestampButEarlier = makeEntry(
            id: id, text: "earlier-event", updatedAt: Date(timeIntervalSince1970: 99)
        )
        let olderTimestampButLater = makeEntry(
            id: id, text: "later-event", updatedAt: Date(timeIntervalSince1970: 1)
        )
        let result = HistoryChangeReconciler.coalesced([
            .changed(newerTimestampButEarlier),
            .changed(olderTimestampButLater)
        ])
        XCTAssertEqual(result.count, 1)
        guard case .changed(let entry) = result[0] else {
            XCTFail("Expected change"); return
        }
        XCTAssertEqual(entry.rawTranscription, "later-event")
    }

    func testDistinctIDs_preserveOrderOfFinalEvents() {
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let result = HistoryChangeReconciler.coalesced([
            .changed(makeEntry(id: idA, text: "a1")),
            .changed(makeEntry(id: idB, text: "b1")),
            .changed(makeEntry(id: idA, text: "a2")),
            .deleted(idC)
        ])
        XCTAssertEqual(result.map(\.id), [idB, idA, idC])
        guard case .changed(let entryA) = result[1] else {
            XCTFail("Expected change for idA"); return
        }
        XCTAssertEqual(entryA.rawTranscription, "a2")
    }

    private func makeEntry(id: UUID, text: String,
                           updatedAt: Date = Date(timeIntervalSince1970: 10)) -> SyncableHistoryEntry {
        SyncableHistoryEntry(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1),
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
