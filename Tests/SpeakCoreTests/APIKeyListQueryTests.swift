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

    func testDensityMetrics_preserveNormalModeAndTripleCompactSpacing() {
        XCTAssertEqual(AppVisualDensity.normal.sectionSpacing, 20)
        XCTAssertEqual(AppVisualDensity.normal.pagePadding, 24)
        XCTAssertEqual(AppVisualDensity.normal.cardPadding, 24)
        XCTAssertEqual(AppVisualDensity.normal.cardContentSpacing, 18)
        XCTAssertEqual(AppVisualDensity.normal.listRowVerticalPadding, 4)
        XCTAssertEqual(AppVisualDensity.normal.minimumListRowHeight, 44)
        XCTAssertEqual(AppVisualDensity.normal.listSectionSpacing, 24)

        XCTAssertLessThanOrEqual(
            AppVisualDensity.compact.pagePadding,
            AppVisualDensity.normal.pagePadding / 3
        )
        XCTAssertLessThanOrEqual(
            AppVisualDensity.compact.cardPadding,
            AppVisualDensity.normal.cardPadding / 3
        )
        XCTAssertLessThanOrEqual(
            AppVisualDensity.compact.sectionSpacing,
            AppVisualDensity.normal.sectionSpacing / 3
        )
        XCTAssertTrue(AppVisualDensity.compact.prefersInlineLayout(dynamicTypeSize: .large))
        XCTAssertFalse(AppVisualDensity.compact.prefersInlineLayout(dynamicTypeSize: .accessibility1))
        XCTAssertFalse(AppVisualDensity.normal.prefersInlineLayout(dynamicTypeSize: .large))
        #if os(iOS)
        XCTAssertGreaterThanOrEqual(AppVisualDensity.compact.minimumListRowHeight, 44)
        #else
        XCTAssertGreaterThanOrEqual(AppVisualDensity.compact.minimumListRowHeight, 28)
        #endif
    }
}
