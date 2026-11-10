import XCTest

@testable import SpeakApp

final class LongListPickerItemsTests: XCTestCase {
    private struct Item {
        let id: Int
        let name: String
        let provider: String
        let traits: String
    }

    private let items = [
        Item(id: 1, name: "Zara", provider: "OpenAI", traits: "British female"),
        Item(id: 2, name: "Alex", provider: "OpenAI", traits: "American male"),
        Item(id: 3, name: "Bella", provider: "ElevenLabs", traits: "British female")
    ]

    func testSearch_MatchesTermsAcrossFieldsIgnoringCaseAndWhitespace() {
        XCTAssertEqual(groups(query: " FEMALE  british OPENAI ").flatMap { $0.items.map(\.id) }, [1])
        XCTAssertEqual(groups(query: "Alex").flatMap { $0.items.map(\.id) }, [2])
        XCTAssertTrue(groups(query: "unknown").isEmpty)
    }

    func testGrouping_SortsGroupsAndPreservesInputOrderWithinGroups() {
        let result = groups()
        XCTAssertEqual(result.map(\.title), ["ElevenLabs", "OpenAI"])
        XCTAssertEqual(result.last?.items.map(\.id), [1, 2])
    }

    func testPinnedSelection_IsExcludedFromGroupsAndSurvivesFilters() {
        let catalog = LongListPickerItems(items: items, id: { $0.id })
        XCTAssertEqual(catalog.pinned(selection: 1)?.name, "Zara")
        XCTAssertFalse(groups(selection: 1).flatMap { $0.items.map(\.id) }.contains(1))
        let result = catalog.groups(
            selection: 1, query: "no match", searchText: { [$0.name] }, group: nil, includes: { _ in false }
        )
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(catalog.pinned(selection: 1)?.id, 1)
    }

    func testUngroupedResults_PreserveOrder() {
        let catalog = LongListPickerItems(items: items, id: { $0.id })
        let result = catalog.groups(selection: -1, query: "", searchText: { [$0.name] }, group: nil)
        XCTAssertEqual(result.map(\.title), [""])
        XCTAssertEqual(result.first?.items.map(\.id), [1, 2, 3])
    }

    func testEmptyCatalogAndMissingSelection_ReturnNoResults() {
        let catalog = LongListPickerItems<Item, Int>(items: [], id: { $0.id })
        XCTAssertNil(catalog.pinned(selection: 1))
        XCTAssertTrue(catalog.groups(selection: 1, query: "", searchText: { [$0.name] }, group: nil).isEmpty)
    }

    func testThreshold_UsesMenuThroughTwentyAndSheetAboveIt() {
        XCTAssertFalse(LongListPickerPolicy.usesSheet(count: 0))
        XCTAssertFalse(LongListPickerPolicy.usesSheet(count: 20))
        XCTAssertTrue(LongListPickerPolicy.usesSheet(count: 21))
        XCTAssertFalse(LongListPickerPolicy.usesSheet(count: 21, threshold: 30))
    }

    private func groups(
        selection: Int = -1, query: String = ""
    ) -> [LongListPickerItems<Item, Int>.Group] {
        LongListPickerItems(items: items, id: { $0.id }).groups(
            selection: selection, query: query,
            searchText: { [$0.name, $0.provider, $0.traits] }, group: { $0.provider }
        )
    }
}
