#if os(iOS)
import AppIntents
import Foundation
import XCTest

@testable import SpeakiOSLib

@MainActor
final class TranscriptEntityTests: XCTestCase {
    func testAuthenticatedProjectionPreservesOneRowsIdentityAndExactStoredText() throws {
        let row = self.item(raw: " Raw text \n", polished: " Polished text \n")
        let entity = try TranscriptEntityHistory(snapshot: { [row] }).latest()
        XCTAssertEqual(entity.id, row.id)
        XCTAssertEqual(entity.rawText, row.transcription)
        XCTAssertEqual(entity.polishedText, row.postProcessedTranscription)
        XCTAssertEqual(entity.createdAt, row.createdAt)
        XCTAssertEqual(entity.durationSeconds, row.duration)
    }

    func testSelectionSkipsEmptyRowsAndKeepsPolishedOnlyRowTogether() throws {
        let empty = self.item(raw: " \n", polished: "\t")
        let polishedOnly = self.item(raw: "", polished: "Useful polish", duration: 9)
        let older = self.item(raw: "Older raw")
        let entity = try TranscriptEntityHistory(snapshot: { [empty, polishedOnly, older] }).latest()
        XCTAssertEqual(entity.id, polishedOnly.id)
        XCTAssertEqual(entity.rawText, "", "The stored empty raw field must not be replaced with polished text")
        XCTAssertEqual(entity.polishedText, "Useful polish")
        XCTAssertEqual(entity.durationSeconds, 9)
    }

    func testRawOnlyAndBlankPolishKeepRawWithoutInventingPolishedText() throws {
        let polishes: [String?] = [nil, "", " \n\t"]
        for polished in polishes {
            let row = self.item(raw: "Raw only", polished: polished)
            let entity = try TranscriptEntityHistory(snapshot: { [row] }).latest()
            XCTAssertEqual(entity.rawText, "Raw only")
            XCTAssertNil(entity.polishedText)
        }
    }

    func testSnapshotIsReadOnceAndLaterChangesCannotReplaceSelectedProperties() throws {
        var rows = [self.item(raw: "First", polished: "First polished")]
        let original = rows[0]
        var reads = 0
        let reader = TranscriptEntityHistory(snapshot: { reads += 1; return rows })
        let entity = try reader.latest()
        rows = [self.item(raw: "Newer unrelated text")]
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(entity.id, original.id)
        XCTAssertEqual(entity.rawText, "First")
        XCTAssertEqual(entity.polishedText, "First polished")
    }

    func testNoUsefulHistoryKeepsExistingNoTranscriptionError() {
        for rows in [[], [self.item(raw: "\n", polished: " ")]] {
            XCTAssertThrowsError(try TranscriptEntityHistory(snapshot: { rows }).latest()) { error in
                guard let error = error as? AutomationIntentError, case .noTranscriptionYet = error else {
                    return XCTFail("Empty History must use the existing safe error")
                }
            }
        }
    }

    func testPassiveQueriesPreserveOrderDeduplicateAndNeverReturnText() async throws {
        let first = self.item(raw: "Private raw A", polished: "Private polish A")
        let second = self.item(raw: "Private raw B", duration: 0)
        let query = TranscriptEntityQuery(snapshot: { [first, second] })
        let result = try await query.entities(for: [second.id, UUID(), first.id, second.id])
        XCTAssertEqual(result.map(\.id), [second.id, first.id])
        XCTAssertEqual(result.map(\.createdAt), [second.createdAt, first.createdAt])
        XCTAssertEqual(result.map(\.durationSeconds), [0, first.duration])
        XCTAssertTrue(result.allSatisfy { $0.rawText == nil && $0.polishedText == nil })
    }

    func testDeletedIdentifierDoesNotFallBackToLatest() async throws {
        let deleted = self.item(raw: "Deleted")
        let remaining = self.item(raw: "Unrelated latest")
        var rows = [deleted, remaining]
        let query = TranscriptEntityQuery(snapshot: { rows })
        let before = try await query.entities(for: [deleted.id])
        XCTAssertEqual(before.map(\.id), [deleted.id])
        rows = [remaining]
        let after = try await query.entities(for: [deleted.id])
        XCTAssertTrue(after.isEmpty)
    }

    func testSuggestionsAndEmptyIdentifierQueryDoNotReadHistory() async throws {
        var reads = 0
        let query = TranscriptEntityQuery(snapshot: { reads += 1; throw TranscriptEntityError.historyUnavailable })
        let suggestions = try await query.suggestedEntities()
        let empty = try await query.entities(for: [])
        XCTAssertTrue(suggestions.isEmpty)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(reads, 0)
    }

    func testUnavailableStorageRemainsFailureInActionAndPassiveQuery() async {
        let unavailable: TranscriptEntityHistory.Snapshot = { throw TranscriptEntityError.historyUnavailable }
        XCTAssertThrowsError(try TranscriptEntityHistory(snapshot: unavailable).latest()) {
            XCTAssertEqual($0 as? TranscriptEntityError, .historyUnavailable)
        }
        do {
            _ = try await TranscriptEntityQuery(snapshot: unavailable).entities(for: [UUID()])
            XCTFail("Unavailable storage must not be reported as empty History")
        } catch {
            XCTAssertEqual(error as? TranscriptEntityError, .historyUnavailable)
        }
    }

    func testDurationOnlyUsesFiniteNonnegativeStoredValues() throws {
        for duration in [-1, Double.infinity, -Double.infinity, Double.nan] {
            let entity = try TranscriptEntity(item: self.item(raw: "Text", duration: duration), includeText: true)
            XCTAssertNil(entity.durationSeconds)
        }
        let zero = try TranscriptEntity(item: self.item(raw: "Text", duration: 0), includeText: true)
        XCTAssertEqual(zero.durationSeconds, 0)
    }

    func testInvalidCreationDateFailsWithoutFabricatingMetadata() {
        let row = self.item(raw: "Synthetic private text", createdAt: Date(timeIntervalSinceReferenceDate: .nan))
        XCTAssertThrowsError(try TranscriptEntity(item: row, includeText: true)) {
            XCTAssertEqual($0 as? TranscriptEntityError, .historyUnavailable)
            XCTAssertFalse($0.localizedDescription.contains(row.transcription))
        }
    }

    func testCombinedUTF8BudgetAcceptsBoundaryAndRefusesWithoutTruncation() throws {
        let budget = TranscriptEntity.maximumPayloadBytes - TranscriptEntity.metadataReserveBytes
        let raw = String(repeating: "r", count: budget / 2)
        let polished = String(repeating: "p", count: budget - raw.utf8.count)
        let accepted = try TranscriptEntity(item: self.item(raw: raw, polished: polished), includeText: true)
        XCTAssertEqual(accepted.rawText, raw)
        XCTAssertEqual(accepted.polishedText, polished)
        XCTAssertThrowsError(try TranscriptEntity(
            item: self.item(raw: raw, polished: polished + "p"), includeText: true
        )) { XCTAssertEqual($0 as? TranscriptEntityError, .tooLarge) }
        let unicode = String(repeating: "🎙", count: budget / "🎙".utf8.count)
        XCTAssertNoThrow(try TranscriptEntity(item: self.item(raw: unicode), includeText: true))
        XCTAssertThrowsError(try TranscriptEntity(item: self.item(raw: unicode + "r"), includeText: true)) {
            XCTAssertEqual($0 as? TranscriptEntityError, .tooLarge)
        }
    }

    func testOversizedTextCannotLeakThroughMetadataQuery() async throws {
        let row = self.item(raw: String(repeating: "Private", count: TranscriptEntity.maximumPayloadBytes))
        let result = try await TranscriptEntityQuery(snapshot: { [row] }).entities(for: [row.id])
        XCTAssertEqual(result.map(\.id), [row.id])
        XCTAssertNil(result.first?.rawText)
        XCTAssertNil(result.first?.polishedText)
    }

    private func item(
        raw: String, polished: String? = nil, duration: TimeInterval = 2.5,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> iOSHistoryItem {
        iOSHistoryItem(
            createdAt: createdAt, transcription: raw, postProcessedTranscription: polished, model: "synthetic/model",
            duration: duration, wordCount: 2, originPlatform: "synthetic"
        )
    }
}
#endif
