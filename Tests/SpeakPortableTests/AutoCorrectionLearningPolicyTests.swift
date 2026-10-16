import Foundation
import SpeakCore
import XCTest

final class AutoCorrectionLearningPolicyTests: XCTestCase {
    func testDefaultsAndTiming_MatchMacTrackerAndStepper() {
        XCTAssertTrue(AutoCorrectionLearningPolicy.enabledByDefault)
        XCTAssertEqual(AutoCorrectionLearningPolicy.defaultPromotionThreshold, 2)
        XCTAssertEqual(AutoCorrectionLearningPolicy.promotionThresholdRange, 2...10)
        XCTAssertEqual(AutoCorrectionLearningPolicy.observationSeconds(for: "word"), 10)
        XCTAssertEqual(AutoCorrectionLearningPolicy.observationSeconds(for: "One. Two!?"), 13)
        XCTAssertEqual(AutoCorrectionLearningPolicy.observationSeconds(for: String(repeating: ".", count: 50)), 30)
    }

    func testPreferences_ValidateAndTransferWithoutApproval() throws {
        let enabled = ApplicationPreferenceKey.autoCorrectionsEnabled.rawValue
        let threshold = ApplicationPreferenceKey.autoCorrectionsPromotionThreshold.rawValue
        let defaults = try DesktopConfiguration()
        XCTAssertTrue(defaults.enabled(enabled))
        XCTAssertEqual(defaults.number(threshold), 2)
        for count in [2, 10] {
            let preferences = try DesktopConfiguration(values: [
                enabled: AnyCodable(.bool(false)), threshold: AnyCodable(.int(count))
            ])
            let restored = try JSONDecoder().decode(
                DesktopConfiguration.self, from: JSONEncoder().encode(preferences)
            )
            XCTAssertFalse(restored.enabled(enabled))
            XCTAssertEqual(restored.number(threshold), Double(count))
            XCTAssertEqual(try preferences.applying(preferences.entries).entries, preferences.entries)
            XCTAssertFalse(DesktopConfiguration.fields.contains { $0.key == "correctionLearningApproved" })
        }
        for invalid in [1.0, 2.5, 11.0, .infinity, .nan] {
            XCTAssertThrowsError(try DesktopConfiguration(values: [threshold: AnyCodable(.double(invalid))]))
        }
        XCTAssertThrowsError(try DesktopConfiguration(values: [enabled: AnyCodable(.string("true"))]))
    }
}
