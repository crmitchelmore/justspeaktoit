import XCTest

final class LaunchUITests: XCTestCase {

    func testAppLaunches_withoutCrash() throws {
        let app = XCUIApplication()
        app.launch()

        // App should be running after launch
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10),
                      "App should reach foreground within 10 seconds")
    }

    func testAppLaunches_menuBarExists() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

        // Verify the app has a menu bar (basic UI element check)
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitForExistence(timeout: 5),
                      "App should have a menu bar")
    }
}
