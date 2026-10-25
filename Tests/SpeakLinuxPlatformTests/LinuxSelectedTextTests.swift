import XCTest
import CLinuxSupport

final class LinuxSelectedTextTests: XCTestCase {
    func testSelectionContracts_KeepAuthorityAndPendingReadSeparate() {
        XCTAssertEqual(jsti_atspi_selection_contract_self_test(), 0,
                       "Selection ranges, purpose fencing, consent independence and retained request admission")
    }

    func testMissingSelectionReceipt_RefusesWithoutReading() {
        var bytes = [CChar](repeating: 0, count: 32)
        XCTAssertEqual(jsti_atspi_selection_read(nil, &bytes, bytes.count), 0)
        XCTAssertTrue(bytes.allSatisfy { $0 == 0 })
        jsti_atspi_selection_release(nil)
    }
}
