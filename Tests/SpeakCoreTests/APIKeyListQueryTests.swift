import XCTest
@testable import SpeakCore

final class APIKeyListQueryTests: XCTestCase {
    private let entries = [
        APIKeyListEntry(id: "deepgram", title: "Deepgram", category: "Transcription", isStored: true),
        APIKeyListEntry(id: "openai", title: "OpenAI", category: "Voice Output", isStored: false),
        APIKeyListEntry(id: "openrouter", title: "OpenRouter", category: "Post-processing", isStored: true)
    ]

    func testApply_searchesNameAndCategoryCaseInsensitively() {
        XCTAssertEqual(
            APIKeyListQuery.apply(to: entries, searchText: "VOICE", status: .all, sortOrder: .name).map(\.id),
            ["openai"]
        )
        XCTAssertEqual(
            APIKeyListQuery.apply(to: entries, searchText: "router", status: .all, sortOrder: .name).map(\.id),
            ["openrouter"]
        )
    }

    func testApply_filtersByStoredStatus() {
        XCTAssertEqual(
            APIKeyListQuery.apply(to: entries, searchText: "", status: .stored, sortOrder: .name).map(\.id),
            ["deepgram", "openrouter"]
        )
        XCTAssertEqual(
            APIKeyListQuery.apply(to: entries, searchText: "", status: .missing, sortOrder: .name).map(\.id),
            ["openai"]
        )
    }

    func testApply_sortsStoredFirstThenByName() {
        XCTAssertEqual(
            APIKeyListQuery.apply(to: entries, searchText: "", status: .all, sortOrder: .status).map(\.id),
            ["deepgram", "openrouter", "openai"]
        )
    }

    func testNormalDensity_preservesExistingMetrics() {
        XCTAssertEqual(AppVisualDensity.normal.pagePadding, 24)
        XCTAssertEqual(AppVisualDensity.normal.cardPadding, 24)
        XCTAssertLessThan(AppVisualDensity.compact.pagePadding, AppVisualDensity.normal.pagePadding)
        XCTAssertGreaterThanOrEqual(AppVisualDensity.compact.minimumListRowHeight, 38)
    }
}
