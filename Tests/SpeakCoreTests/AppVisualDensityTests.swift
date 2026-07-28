import XCTest
@testable import SpeakCore

final class AppVisualDensityTests: XCTestCase {
    func testMetrics_preserveNormalModeAndTripleCompactSpacing() {
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

    func testAdaptiveColumnCount_usesWidthOnlyInCompactMode() {
        XCTAssertEqual(
            AppVisualDensity.normal.adaptiveColumnCount(availableWidth: 1_100),
            1
        )
        XCTAssertEqual(
            AppVisualDensity.compact.adaptiveColumnCount(availableWidth: 320),
            1
        )
        XCTAssertEqual(
            AppVisualDensity.compact.adaptiveColumnCount(availableWidth: 700),
            2
        )
        XCTAssertEqual(
            AppVisualDensity.compact.adaptiveColumnCount(availableWidth: 1_100),
            3
        )
        XCTAssertEqual(
            AppVisualDensity.compact.adaptiveColumnCount(
                availableWidth: 2_000,
                maximumColumns: 2
            ),
            2
        )
    }
}
