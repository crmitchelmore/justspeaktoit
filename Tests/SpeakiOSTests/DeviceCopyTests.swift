#if os(iOS)
import XCTest

@testable import SpeakiOSLib

final class DeviceCopyTests: XCTestCase {
    func testName_followsInterfaceIdiom() {
        XCTAssertEqual(DeviceCopy.name(for: .phone), "iPhone")
        XCTAssertEqual(DeviceCopy.name(for: .pad), "iPad")
        XCTAssertEqual(DeviceCopy.name(for: .pad, isiOSAppOnMac: true), "Mac")
        XCTAssertEqual(DeviceCopy.name(for: .carPlay), "device")
    }

    func testLiveActivityPlacement_mentionsDynamicIslandOnlyOnIPhone() {
        XCTAssertTrue(DeviceCopy.liveActivityPlacement(for: .phone).contains("Dynamic Island"))
        XCTAssertEqual(DeviceCopy.liveActivityPlacement(for: .pad), "on the Lock Screen")
    }
}
#endif
