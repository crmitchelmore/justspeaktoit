import CLinuxSupport
import XCTest

final class LinuxClipboardReadTests: XCTestCase {
    func testSyntheticStreamLimitUnicodeAndCancellation_NeverReadsDisplayClipboard() {
        var error = [CChar](repeating: 0, count: 1024)
        let result = jsti_linux_clipboard_read_self_test(&error, error.count)
        XCTAssertEqual(result, 0, String(cString: error))
    }
}
