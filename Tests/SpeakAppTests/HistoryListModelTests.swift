import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

@MainActor
final class HistoryListModelTests: XCTestCase {
  func testShow_listsEveryModelOnceAndKeepsFilters() {
    let list = HistoryListModel()
    list.searchText = "alpha"

    list.show([
      self.makeItem(text: "alpha one", model: "deepgram/nova-3"),
      self.makeItem(text: "beta", model: "deepgram/nova-3"),
      self.makeItem(text: "alpha two", model: "apple/local/SFSpeechRecognizer")
    ])

    XCTAssertEqual(list.filteredItems.map(\.rawTranscription), ["alpha one", "alpha two"])
    XCTAssertEqual(Set(list.availableModels), ["deepgram/nova-3", "apple/local/SFSpeechRecognizer"])
    XCTAssertEqual(list.availableModels.count, 2)
  }

  func testFilterChange_startsAgainFromTheFirstPage() {
    let list = HistoryListModel()
    list.show((0..<(HistoryPageWindow.defaultPageSize + 5)).map { self.makeItem(text: "item \($0)") })
    list.loadMore()
    XCTAssertEqual(list.displayedItems.count, HistoryPageWindow.defaultPageSize + 5)

    list.searchText = "item"

    XCTAssertEqual(list.displayedItems.count, HistoryPageWindow.defaultPageSize)
    XCTAssertTrue(list.hasMore)
  }

  func testClearFilters_restoresTheUnfilteredList() {
    let list = HistoryListModel()
    list.show([self.makeItem(text: "kept"), self.makeItem(text: "other")])
    list.searchText = "kept"
    list.dateRangeEnabled = true
    XCTAssertTrue(list.isFilterActive)

    list.clearFilters()

    XCTAssertFalse(list.isFilterActive)
    XCTAssertEqual(list.filteredItems.count, 2)
  }

  private func makeItem(text: String, model: String = "deepgram/nova-3") -> HistoryItem {
    HistoryItem(
      id: UUID(),
      createdAt: Date(),
      modelsUsed: [model],
      rawTranscription: text,
      postProcessedTranscription: nil,
      recordingDuration: 1,
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
        hotKeyDescription: "Synthetic",
        outputMethod: .clipboard,
        destinationApplication: nil
      ),
      personalCorrections: nil,
      errors: []
    )
  }
}
