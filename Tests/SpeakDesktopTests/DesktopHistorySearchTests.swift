import Foundation
import SpeakCore
@testable import SpeakDesktop
import XCTest

final class DesktopHistorySearchTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testFold_IgnoresCaseDiacriticsAndWhitespaceRuns() {
        XCTAssertEqual(DesktopHistorySearch.fold("Café"), "cafe")
        XCTAssertEqual(DesktopHistorySearch.fold("CAFE\u{301}"), "cafe")
        XCTAssertEqual(DesktopHistorySearch.fold("Ångström naïve Ñandú"), "angstrom naive nandu")
        XCTAssertEqual(DesktopHistorySearch.fold("  hello \n\t world  "), "hello world")
        XCTAssertEqual(DesktopHistorySearch.fold(" \n "), "")
        XCTAssertEqual(DesktopHistorySearch.fold("İstanbul"), "istanbul")
        XCTAssertEqual(DesktopHistorySearch.fold("こんにちは 🎙"), "こんにちは 🎙")
        XCTAssertFalse(DesktopHistorySearch.isActive("\t \n"))
        XCTAssertTrue(DesktopHistorySearch.isActive(" é "))
    }

    func testFilter_MatchesOriginalProcessedAndCanonicalFriendlyModelName() throws {
        let original = try makeRecord(
            original: "Résumé of the meeting", processed: "Summary of the meeting.",
            model: "openai/whisper-1", createdAt: base
        )
        let processedOnly = try makeRecord(
            original: "plain words", processed: "Plain words with Zürich.", model: "openai/whisper-1",
            createdAt: base.addingTimeInterval(-1)
        )
        let parakeet = try makeRecord(
            original: "unrelated", processed: nil, model: ParakeetLocalModels.tdtV3Int8SourceID,
            createdAt: base.addingTimeInterval(-2)
        )
        let pending = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: "p.wav", modelIdentifier: "openai/whisper-1"
        )
        let records = [pending, parakeet, processedOnly, original]

        XCTAssertEqual(DesktopHistorySearch.filter(records, query: "RESUME").map(\.id), [original.id])
        XCTAssertEqual(DesktopHistorySearch.filter(records, query: "zurich").map(\.id), [processedOnly.id])
        XCTAssertEqual(
            DesktopHistorySearch.filter(records, query: "parakeet").map(\.id), [parakeet.id],
            "Search must match the canonical friendly model name, not only the identifier"
        )
        XCTAssertEqual(
            DesktopHistorySearch.filter(records, query: "  Meeting ").map(\.id), [original.id],
            "Query whitespace is trimmed before matching"
        )
        XCTAssertTrue(DesktopHistorySearch.filter(records, query: "no such phrase").isEmpty)
        XCTAssertEqual(
            DesktopHistorySearch.modelDisplayName(for: parakeet.modelIdentifier),
            ModelCatalog.friendlyName(for: parakeet.modelIdentifier)
        )
        XCTAssertTrue(DesktopHistorySearch.matches(query: "", searchText: ""))
        XCTAssertFalse(DesktopHistorySearch.matches(query: "x", searchText: ""))
    }

    func testFilter_PreservesIdentifiersAndDeterministicNewestFirstOrder() throws {
        let newest = try makeRecord(
            original: "match one", processed: nil, model: "test", createdAt: base.addingTimeInterval(10)
        )
        let tieA = try makeRecord(
            original: "match two", processed: nil, model: "test", createdAt: base,
            id: XCTUnwrap(UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000"))
        )
        let tieB = try makeRecord(
            original: "match three", processed: nil, model: "test", createdAt: base,
            id: XCTUnwrap(UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000"))
        )
        let oldest = try makeRecord(
            original: "match four", processed: nil, model: "test", createdAt: base.addingTimeInterval(-10)
        )
        let shuffled = [tieB, oldest, newest, tieA]

        let all = DesktopHistorySearch.filter(shuffled, query: "")
        XCTAssertEqual(all.map(\.id), [newest.id, tieA.id, tieB.id, oldest.id])
        XCTAssertEqual(all.map(\.id), DesktopHistorySearch.ordered(shuffled.reversed()).map(\.id))
        let matched = DesktopHistorySearch.filter(shuffled, query: "match")
        XCTAssertEqual(matched.map(\.id), all.map(\.id), "Filtering keeps the same stable identifiers and order")
        XCTAssertEqual(matched.map(\.originalText), all.map(\.originalText))
        XCTAssertEqual(DesktopHistorySearch.filter(shuffled, query: "t").map(\.id), all.map(\.id))
    }

    func testCachedSearchText_MatchesTheDefaultPolicyWithoutSpanningFields() throws {
        let record = try makeRecord(original: "alpha end", processed: "start omega", model: "openai/whisper-1")
        let cache = [record.id: DesktopHistorySearch.searchText(for: record)]
        let cached = DesktopHistorySearch.filter([record], query: "OMEGA") { cache[$0.id] ?? "" }
        XCTAssertEqual(cached.map(\.id), [record.id])
        XCTAssertTrue(
            DesktopHistorySearch.filter([record], query: "end start").isEmpty,
            "A query must not match across the boundary between two transcripts"
        )
        XCTAssertTrue(DesktopHistorySearch.matches(query: "whisper", searchText: try XCTUnwrap(cache[record.id])))
    }

    func testTranscriptVariants_DefaultToProcessedAndExposeOriginal() throws {
        var record = try makeRecord(original: "word one", processed: "Word. One.", model: "test")
        XCTAssertTrue(record.hasTranscriptVariants)
        XCTAssertEqual(record.text(for: .processed), "Word. One.")
        XCTAssertEqual(record.text(for: .processed), record.displayText)
        XCTAssertEqual(record.text(for: .original), "word one")
        XCTAssertEqual(DesktopTranscriptVariant.allCases, [.processed, .original])

        record.processedText = nil
        XCTAssertFalse(record.hasTranscriptVariants)
        XCTAssertEqual(record.text(for: .processed), "word one", "Processed falls back to the original display text")
        XCTAssertEqual(record.text(for: .original), "word one")

        let pending = DesktopRecordingStore.Record(id: UUID(), audioFilename: "p.wav", modelIdentifier: "test")
        XCTAssertFalse(pending.hasTranscriptVariants)
        XCTAssertNil(pending.text(for: .processed))
        XCTAssertNil(pending.text(for: .original))
    }

    func testExport_UsesRequestedVariantWithoutTouchingTheRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("History")
        let store = try DesktopRecordingStore(directory: directory)
        let record = try makeRecord(original: "raw café", processed: "Polished café.", model: "test")
        try Data([9, 8, 7]).write(to: directory.appendingPathComponent(record.audioFilename))
        try await store.save(record)
        let metadataURL = directory.appendingPathComponent(record.id.uuidString + ".json")
        let metadata = try Data(contentsOf: metadataURL)

        let original = root.appendingPathComponent("original.txt")
        try await store.exportTranscript(id: record.id, variant: .original, to: original)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "raw café")
        let processed = root.appendingPathComponent("processed.txt")
        try await store.exportTranscript(id: record.id, variant: .processed, to: processed)
        XCTAssertEqual(try String(contentsOf: processed, encoding: .utf8), "Polished café.")
        let legacy = root.appendingPathComponent("legacy.txt")
        try await store.exportTranscript(id: record.id, to: legacy)
        XCTAssertEqual(
            try String(contentsOf: legacy, encoding: .utf8), "Polished café.", "Existing callers keep processed"
        )

        let saved = try await store.record(id: record.id)
        XCTAssertEqual(saved.originalText, "raw café")
        XCTAssertEqual(saved.processedText, "Polished café.")
        XCTAssertEqual(try Data(contentsOf: metadataURL), metadata)
        let audio = try await store.audioURL(for: saved)
        XCTAssertEqual(try Data(contentsOf: audio), Data([9, 8, 7]))
    }

    func testFailedOrCancelledPostProcessing_RetainsOriginalForSearchAndExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DesktopRecordingStore(directory: root.appendingPathComponent("History"))
        var record = try makeRecord(original: "Original stays", processed: nil, model: "test")
        record.postProcessingFailure = "Cancelled"
        record.failure = "Cancelled. Completed transcription and audio retained."
        try await store.save(record)

        XCTAssertEqual(DesktopHistorySearch.filter([record], query: "original stays").map(\.id), [record.id])
        XCTAssertFalse(record.hasTranscriptVariants)
        let export = root.appendingPathComponent("retained.txt")
        try await store.exportTranscript(id: record.id, variant: .original, to: export)
        XCTAssertEqual(try String(contentsOf: export, encoding: .utf8), "Original stays")
        try await store.exportTranscript(id: record.id, variant: .processed, to: export)
        XCTAssertEqual(try String(contentsOf: export, encoding: .utf8), "Original stays")
        let pending = DesktopRecordingStore.Record(id: UUID(), audioFilename: "none.wav", modelIdentifier: "test")
        try await store.save(pending)
        for variant in DesktopTranscriptVariant.allCases {
            do {
                try await store.exportTranscript(id: pending.id, variant: variant, to: export)
                XCTFail("Exported a transcript that does not exist")
            } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadUnknown) }
        }
    }

    /// Decodes a record so tests control `createdAt`, which the public
    /// initialiser always stamps with the current time.
    private func makeRecord(
        original: String, processed: String?, model: String, createdAt: Date? = nil, id: UUID = UUID()
    ) throws -> DesktopRecordingStore.Record {
        let created = (createdAt ?? Date()).timeIntervalSinceReferenceDate
        let json = """
        {"id":"\(id.uuidString)","createdAt":\(created),\
        "audioFilename":"\(id.uuidString).wav","modelIdentifier":"\(model)"}
        """
        var record = try JSONDecoder().decode(DesktopRecordingStore.Record.self, from: Data(json.utf8))
        record.result = TranscriptionResult(
            text: original, segments: [], confidence: nil, duration: 1, modelIdentifier: model,
            cost: nil, rawPayload: nil, debugInfo: nil
        )
        record.processedText = processed
        return record
    }
}
