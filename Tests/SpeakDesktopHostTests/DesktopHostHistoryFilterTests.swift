import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

final class DesktopHostHistoryFilterTests: XCTestCase {
    func testHiddenSelectionIsClearedAndStaleSelectionIsRefusedWithoutChangingHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-filter-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        let first = record()
        var failed = record()
        failed.postProcessingFailure = "Synthetic failure"
        await controller.indexHistory(first)
        await controller.indexHistory(failed)
        await controller.selectHistory(first.id.uuidString)
        await controller.applyHistoryFilters(try payload(DesktopHistoryFilter(errorsOnly: true)))
        let selected = await controller.selectedHistoryID
        let visible = await controller.visibleHistory().map(\.id)
        let text = await controller.transcript
        XCTAssertNil(selected)
        XCTAssertEqual(visible, [failed.id])
        XCTAssertEqual(text, "")
        await controller.selectHistory(first.id.uuidString)
        let stale = await controller.selectedHistoryID
        XCTAssertNil(stale)
        await controller.applyHistoryFilters(try payload(.none))
        let restored = await controller.visibleHistory().map(\.id)
        XCTAssertEqual(Set(restored), [first.id, failed.id])
        let retained = await controller.history[first.id]
        XCTAssertEqual(retained?.originalText, first.originalText)
        XCTAssertEqual(retained?.result, first.result)
        await controller.close()
    }

    func testMalformedAndUnknownModelFiltersDoNotReplaceTheCurrentFilter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-filter-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        var entry = record()
        entry.failure = "Synthetic failure"
        await controller.indexHistory(entry)
        await controller.applyHistoryFilters(try payload(DesktopHistoryFilter(errorsOnly: true)))
        for invalid in [
            "not JSON",
            try payload(DesktopHistoryFilter(models: ["unrecorded/model"])),
            try payload(DesktopHistoryFilter(fromDay: "2026-02-30")),
            try payload(DesktopHistoryFilter(fromDay: "2026-10-10", throughDay: "2026-10-09"))
        ] {
            await controller.applyHistoryFilters(invalid)
            let draft = await controller.historyFilterDraft
            XCTAssertEqual(draft, DesktopHistoryFilter(errorsOnly: true))
        }
        XCTAssertTrue(FakeLog.shared.allStatuses.contains { $0.hasPrefix("Could not filter History:") })
        await controller.close()
    }

    func testHistoryList_showsOnePageAndGrowsWhileSearchCoversEveryRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-page-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try DesktopHostController<FakePlatform>(directory: directory, effects: SyntheticEffects())
        await controller.markReadyForSelfTest()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var records: [DesktopRecordingStore.Record] = []
        for index in 0..<250 {
            var entry = record(createdAt: start.addingTimeInterval(TimeInterval(-index)))
            if index == 240 { entry.processedText = "Needle transcript" }
            records.append(entry)
            await controller.indexHistory(entry)
        }
        await controller.refreshHistory()
        var shown = await controller.displayedHistory(controller.visibleHistory())
        XCTAssertEqual(shown.map(\.id), records.prefix(100).map(\.id))

        await controller.loadMoreHistory()
        await controller.loadMoreHistory()
        await controller.loadMoreHistory()
        shown = await controller.displayedHistory(controller.visibleHistory())
        XCTAssertEqual(shown.count, 250)

        await controller.searchHistory("needle")
        shown = await controller.displayedHistory(controller.visibleHistory())
        XCTAssertEqual(shown.map(\.id), [records[240].id], "Search covers rows beyond the loaded page")
        let page = await controller.historyPage
        XCTAssertEqual(page.limit, HistoryPageWindow.defaultPageSize)

        await controller.searchHistory("")
        await controller.selectHistory(records[240].id.uuidString)
        shown = await controller.displayedHistory(controller.visibleHistory())
        XCTAssertTrue(shown.contains { $0.id == records[240].id }, "A selection is never paged out")
        await controller.close()
    }

    private func payload(_ filter: DesktopHistoryFilter) throws -> String {
        try XCTUnwrap(String(bytes: JSONEncoder().encode(filter), encoding: .utf8))
    }

    private func record(createdAt: Date = Date()) -> DesktopRecordingStore.Record {
        var record = DesktopRecordingStore.Record(id: UUID(), audioFilename: "synthetic.wav",
                                                   modelIdentifier: "openai/whisper-1", createdAt: createdAt)
        record.result = TranscriptionResult(
            text: "Synthetic transcript", segments: [], confidence: nil, duration: 1,
            modelIdentifier: record.modelIdentifier, cost: nil, rawPayload: nil, debugInfo: nil
        )
        return record
    }
}
