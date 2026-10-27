import XCTest

extension XCUIApplication {
    /// Fresh owned simulators may present onboarding after the root appears.
    /// Exercise its real Skip control without granting access or starting audio.
    func skipFirstRunForUITest(ready element: XCUIElement) throws {
        let finish = buttons["firstRunFinishButton"]
        let appeared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            element.exists || finish.exists
        }, object: nil)
        guard XCTWaiter.wait(for: [appeared], timeout: 60) == .completed else {
            XCTFail("Neither the app's root nor its onboarding appeared")
            throw AppLaunchTimeout()
        }
        // Allow the root's asynchronous onboarding presentation to arrive even
        // when its underlying Settings/record control already exists.
        if finish.waitForExistence(timeout: 15) {
            guard finish.label == "Skip", finish.isEnabled, finish.isHittable else {
                XCTFail("Expected the actual idle onboarding Skip control")
                throw AppLaunchTimeout()
            }
            finish.tap()
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !finish.exists && element.exists && element.isHittable
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 15) == .completed else {
            XCTFail("Onboarding did not dismiss to a reachable app control")
            throw AppLaunchTimeout()
        }
    }
}

private struct AppLaunchTimeout: Error {}
