import SpeakHotKeys
import XCTest

final class HotKeyMappingTests: XCTestCase {
    func testSingleKeyHotKeyCodes_includeExtendedFunctionKeysInsertAndISOSectionKey() {
        for keyCode in [UInt16(10), 64, 79, 80, 90, 105, 106, 107, 113, 114] {
            XCTAssertTrue(KeyCodeMapping.singleKeyHotKeyCodes.contains(keyCode))
        }
    }

    func testDisplayStrings_includeExtendedFunctionKeysInsertAndISOSectionKey() {
        XCTAssertEqual(KeyCodeMapping.string(for: 10), "§/±")
        XCTAssertEqual(KeyCodeMapping.string(for: 105), "F13")
        XCTAssertEqual(KeyCodeMapping.string(for: 106), "F16")
        XCTAssertEqual(KeyCodeMapping.string(for: 64), "F17")
        XCTAssertEqual(KeyCodeMapping.string(for: 114), "Insert")
    }
}
