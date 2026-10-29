#if os(iOS)
import Combine
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib

@MainActor
final class HistoryViewRefreshTests: XCTestCase {
    func testPublishedPayloadRefreshesSameIDDuringWillSetWithoutUnrelatedRebuilds() {
        let original = item(text: "before")
        let replacement = item(id: original.id, text: "after change")
        let publisher = HistoryItemsPublisher(items: [original])
        var builds = 0
        var storedTextAtDelivery: String?
        var state: HistoryViewDerivedState?
        let subscription = publisher.$items.sink { emitted in
            builds += 1
            storedTextAtDelivery = publisher.items.first?.transcription
            state = HistoryViewDerivedState(items: emitted, query: .none)
        }
        defer { subscription.cancel() }
        XCTAssertEqual(builds, 1)
        for _ in 0..<25 { publisher.unrelated.toggle() }
        XCTAssertEqual(builds, 1)

        publisher.items = [replacement]

        XCTAssertEqual(builds, 2)
        XCTAssertEqual(storedTextAtDelivery, "before")
        XCTAssertEqual(state?.filteredItems.first?.id, original.id)
        XCTAssertEqual(state?.filteredItems.first?.transcription, "after change")
        XCTAssertEqual(state?.statistics.totalWords, 2)
        XCTAssertEqual(publisher.items.first?.transcription, "after change")
    }

    func testSameIDTranscriptAndPolishEditsReevaluateSearchAndStatistics() {
        let original = item(text: "old words")
        let query = HistorySearchQuery(searchText: "new")
        XCTAssertTrue(HistoryViewDerivedState(items: [original], query: query).filteredItems.isEmpty)

        let edited = item(id: original.id, text: "new raw text")
        let rawState = HistoryViewDerivedState(items: [edited], query: query)
        XCTAssertEqual(rawState.filteredItems.map(\.id), [original.id])
        XCTAssertEqual(rawState.statistics.totalWords, 3)

        let polished = original.withPostProcessed("new polished words here")
        let polishedState = HistoryViewDerivedState(items: [polished], query: query)
        XCTAssertEqual(polishedState.filteredItems.map(\.id), [original.id])
        XCTAssertEqual(polishedState.filteredItems.first?.transcription, "old words")
        XCTAssertEqual(polishedState.statistics.totalWords, 4)
    }

    func testSameIDErrorAdditionAndRemovalReevaluateErrorsOnly() {
        let original = item(text: "recording")
        let query = HistorySearchQuery(includeErrorsOnly: true)
        XCTAssertTrue(HistoryViewDerivedState(items: [original], query: query).filteredItems.isEmpty)
        let errored = original.withError("owned test error")
        let state = HistoryViewDerivedState(items: [errored], query: query)
        XCTAssertEqual(state.filteredItems.map(\.id), [original.id])
        XCTAssertEqual(state.statistics.sessionsWithErrors, 1)
        XCTAssertTrue(HistoryViewDerivedState(items: [errored.withError(nil)], query: query).filteredItems.isEmpty)
    }

    func testSameIDModelDurationAndDateChangesKeepCurrentRowsAndAllModelChoices() {
        let original = item(text: "first", model: "model-a", duration: 1)
        let other = item(text: "second", model: "model-a", duration: 5)
        let updated = item(id: original.id, text: "first", model: "model-b", duration: 12, date: 200)
        let query = HistorySearchQuery(
            modelIdentifiers: ["model-b"],
            dateRange: Date(timeIntervalSince1970: 150)...Date(timeIntervalSince1970: 250)
        )
        XCTAssertTrue(HistoryViewDerivedState(items: [original, other], query: query).filteredItems.isEmpty)
        let state = HistoryViewDerivedState(items: [updated, other], query: query)
        XCTAssertEqual(state.filteredItems.map(\.id), [original.id])
        XCTAssertEqual(state.filteredItems.first?.model, "model-b")
        XCTAssertEqual(state.statistics.cumulativeRecordingDuration, 12)
        XCTAssertEqual(state.statistics.averageSessionLength, 12)
        XCTAssertEqual(Set(state.availableModels), ["model-a", "model-b"])
    }

    func testAdditionRemovalAndEmptyPublicationKeepOrderAndResetStatistics() {
        let first = item(text: "one two", duration: 2)
        let second = item(text: "three", duration: 4)
        let added = HistoryViewDerivedState(items: [second, first], query: .none)
        XCTAssertEqual(added.filteredItems.map(\.id), [second.id, first.id])
        XCTAssertEqual(added.statistics.totalSessions, 2)
        XCTAssertEqual(added.statistics.totalWords, 3)
        XCTAssertEqual(added.statistics.cumulativeRecordingDuration, 6)
        let removed = HistoryViewDerivedState(items: [second], query: .none)
        XCTAssertEqual(removed.filteredItems.map(\.id), [second.id])
        XCTAssertEqual(removed.statistics.totalWords, 1)
        let empty = HistoryViewDerivedState(items: [], query: .none)
        XCTAssertTrue(empty.filteredItems.isEmpty)
        XCTAssertTrue(empty.availableModels.isEmpty)
        XCTAssertEqual(empty.statistics, HistoryPresentationStatistics(items: []))
    }

    func testRichCostChangeRemainsInCurrentRowWithoutChangingIOSCostPresentation() {
        let id = UUID()
        func row(cost: Decimal) -> iOSHistoryItem {
            iOSHistoryItem(historyRecord: HistoryRecord(
                id: id, rawTranscription: "owned text", recordingDuration: 3,
                cost: ApplicationHistoryCost(total: cost, currency: "USD"), model: "model-a",
                originPlatform: "ios"
            ))
        }
        let before = HistoryViewDerivedState(items: [row(cost: 1)], query: .none)
        let after = HistoryViewDerivedState(items: [row(cost: 2)], query: .none)
        XCTAssertEqual(before.filteredItems.first?.historyRecord.cost?.total, 1)
        XCTAssertEqual(after.filteredItems.first?.historyRecord.cost?.total, 2)
        XCTAssertEqual(after.filteredItems.first?.id, id)
        // The canonical iOS presentation deliberately excludes rich record costs.
        XCTAssertEqual(before.statistics.totalSpend, 0)
        XCTAssertEqual(after.statistics.totalSpend, 0)
    }

    func testEachFilterInputInvalidatesTheSmallKeyWithoutAnyRows() {
        func key(
            text: String = "", errors: Bool = false, model: String? = nil,
            ranged: Bool = false, start: TimeInterval = 100, end: TimeInterval = 200
        ) -> HistoryViewFilterKey {
            HistoryViewFilterKey(
                searchText: text, errorsOnly: errors, selectedModel: model, dateRangeEnabled: ranged,
                startDate: Date(timeIntervalSince1970: start), endDate: Date(timeIntervalSince1970: end)
            )
        }
        let original = key()
        XCTAssertEqual(original, key())
        for changed in [key(text: "words"), key(errors: true), key(model: "model-a"),
                        key(ranged: true), key(start: 90), key(end: 210)] {
            XCTAssertNotEqual(original, changed)
        }
    }

    private func item(
        id: UUID = UUID(), text: String, model: String = "model-a",
        duration: TimeInterval = 1, date: TimeInterval = 100
    ) -> iOSHistoryItem {
        iOSHistoryItem(
            id: id, createdAt: Date(timeIntervalSince1970: date), transcription: text,
            model: model, duration: duration, wordCount: text.split(separator: " ").count
        )
    }
}

@MainActor
private final class HistoryItemsPublisher: ObservableObject {
    @Published var items: [iOSHistoryItem]
    @Published var unrelated = false

    init(items: [iOSHistoryItem]) { self.items = items }
}
#endif
