import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

final class HistorySpendFormatTests: XCTestCase {
    func testSpendTotals_keepSubCentAmountsVisible() {
        let subCent = Decimal(string: "0.0042")!
        let shared = HistoryDetailFormatting.formatCurrency(subCent, currency: "USD")
        XCTAssertTrue(shared.contains("0.0042"))
        XCTAssertEqual(HistoryHeaderFormat.currency(subCent), shared)
        XCTAssertEqual(DashboardFormat.currency(subCent), shared)
        XCTAssertEqual(DashboardFormat.currency(0), "—")
    }
}
