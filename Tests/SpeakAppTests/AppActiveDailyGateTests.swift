import Foundation
import XCTest

@testable import SpeakApp

final class AppActiveDailyGateTests: XCTestCase {
    func testDailyGate_firesOncePerCalendarDay() throws {
        let suite = "AppActiveDailyGateTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        self.addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let gate = AppActiveDailyGate(defaults: defaults, calendar: calendar, now: { now })

        XCTAssertTrue(gate.isDue(on: gate.startOfToday()), "A first launch is due")
        gate.markCaptured(on: gate.startOfToday())
        now.addTimeInterval(60 * 60)
        XCTAssertFalse(gate.isDue(on: gate.startOfToday()), "A later launch the same day is not")
        now.addTimeInterval(24 * 60 * 60)
        XCTAssertTrue(gate.isDue(on: gate.startOfToday()), "The next day is due again")
    }
}
