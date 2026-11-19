import XCTest
@testable import SpeakCore

final class HistoryPageWindowTests: XCTestCase {
    func testWindow_startsAtOnePageAndGrowsUntilEveryRowIsShown() {
        var window = HistoryPageWindow(pageSize: 100)
        XCTAssertEqual(window.visibleCount(of: 10_000), 100)
        XCTAssertEqual(window.visibleCount(of: 40), 40)
        XCTAssertTrue(window.hasMore(total: 250))
        XCTAssertTrue(window.loadMore(total: 250))
        XCTAssertTrue(window.loadMore(total: 250))
        XCTAssertEqual(window.visibleCount(of: 250), 250)
        XCTAssertFalse(window.hasMore(total: 250))
        XCTAssertFalse(window.loadMore(total: 250))
        XCTAssertEqual(window.limit, 300)
    }

    func testReset_returnsToTheFirstPage() {
        var window = HistoryPageWindow(pageSize: 50)
        window.loadMore(total: 1_000)
        window.reset()
        XCTAssertEqual(window.visibleCount(of: 1_000), 50)
    }

    func testReveal_growsInWholePagesToIncludeTheRow() {
        var window = HistoryPageWindow(pageSize: 100)
        window.reveal(index: 99)
        XCTAssertEqual(window.limit, 100)
        window.reveal(index: 100)
        XCTAssertEqual(window.limit, 200)
        window.reveal(index: 4_321)
        XCTAssertEqual(window.limit, 4_400)
        window.reveal(index: 5)
        XCTAssertEqual(window.limit, 4_400)
    }

    func testInvalidPageSize_isClampedToOne() {
        let window = HistoryPageWindow(pageSize: 0)
        XCTAssertEqual(window.pageSize, 1)
        XCTAssertEqual(window.visibleCount(of: -3), 0)
    }
}
