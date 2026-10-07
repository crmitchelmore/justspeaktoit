import XCTest
import SpeakDesktop

final class DesktopLoginItemTests: XCTestCase {
    func testOnlyTheLaunchArgumentMarksALoginLaunch() {
        XCTAssertTrue(DesktopLoginItem.isLoginLaunch(["justspeaktoit", "--background"]))
        XCTAssertTrue(DesktopLoginItem.isLoginLaunch([#"C:\Apps\SpeakWindows.exe"#, "--toggle", "--background"]))
        XCTAssertFalse(DesktopLoginItem.isLoginLaunch(["justspeaktoit"]))
        XCTAssertFalse(DesktopLoginItem.isLoginLaunch(["--background"]), "the executable path is not an argument")
        XCTAssertFalse(DesktopLoginItem.isLoginLaunch(["justspeaktoit", "--background=1"]))
    }

    func testStatesKeepTheirNativeValues() {
        XCTAssertEqual(DesktopLoginItemState.allCases.map(\.rawValue), [0, 1, 2, 3, 4])
        XCTAssertEqual(DesktopLoginItemState.allCases.filter(\.launchesAtLogin), [.enabled, .enabledBySystem])
        XCTAssertEqual(DesktopLoginItemState.allCases.filter(\.isChangeable), [.disabled, .enabled])
    }

    func testEveryStateHasItsOwnWording() {
        let place = "Settings › Apps › Startup"
        for state in DesktopLoginItemState.allCases {
            XCTAssertFalse(DesktopLoginItem.detail(state, systemSettings: place).isEmpty)
            XCTAssertFalse(DesktopLoginItem.status(state, systemSettings: place).isEmpty)
        }
        XCTAssertTrue(DesktopLoginItem.detail(.disabledBySystem, systemSettings: place).contains(place))
        let statuses = Set(DesktopLoginItemState.allCases.map { DesktopLoginItem.status($0, systemSettings: place) })
        XCTAssertEqual(statuses.count, DesktopLoginItemState.allCases.count)
    }
}
