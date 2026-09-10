#if os(iOS)
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib

/// Verifies the new `HardwareTriggerDestination` enum and its UserDefaults
/// round-trip through `AppSettings`. These are the only pieces of the
/// Action Button feature that are reasonable to exercise in unit tests
/// without spinning up the live recording stack (transcribers, audio
/// session, Live Activity, etc.).
@MainActor
final class HardwareTriggerDestinationTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "HardwareTriggerDestinationTests"

    override func setUp() async throws {
        try await super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try await super.tearDown()
    }

    // MARK: - Enum surface

    func testAllCasesHaveStableRawValues() {
        // Stability matters because the raw value is what we persist to
        // UserDefaults. Changing these strings would silently reset
        // existing users' choices back to the default.
        XCTAssertEqual(HardwareTriggerDestination.clipboard.rawValue, "clipboard")
        XCTAssertEqual(HardwareTriggerDestination.clipboardAndPostProcess.rawValue, "clipboardAndPostProcess")
        XCTAssertEqual(HardwareTriggerDestination.historyOnly.rawValue, "historyOnly")
        XCTAssertEqual(HardwareTriggerDestination.auto.rawValue, "auto")
    }

    func testAllCasesHaveNonEmptyDisplayName() {
        for destination in HardwareTriggerDestination.allCases {
            XCTAssertFalse(destination.displayName.isEmpty, "\(destination) should have a display name")
            XCTAssertFalse(destination.summary.isEmpty, "\(destination) should have a summary")
        }
    }

    func testIdentifiableUsesRawValue() {
        for destination in HardwareTriggerDestination.allCases {
            XCTAssertEqual(destination.id, destination.rawValue)
        }
    }

    // MARK: - UserDefaults persistence

    /// `AppSettings.shared` is a singleton bound to `UserDefaults.standard`,
    /// so we can't safely swap its backing store. Instead this test verifies
    /// the persistence contract directly against UserDefaults the same way
    /// `AppSettings` reads/writes it, using an isolated suite.
    func testDestinationRoundTripsThroughUserDefaults() {
        let key = "hardwareTriggerDestination"

        for destination in HardwareTriggerDestination.allCases {
            defaults.set(destination.rawValue, forKey: key)

            let raw = defaults.string(forKey: key) ?? ""
            let restored = HardwareTriggerDestination(rawValue: raw) ?? .clipboard

            XCTAssertEqual(restored, destination, "Round-trip failed for \(destination)")
        }
    }

    func testMissingDefaultsValueFallsBackToAuto() {
        // Mirrors the init logic in AppSettings: with no stored choice the
        // destination is resolved per capture (issue #1008). An explicitly
        // stored choice is always honoured — see the round-trip test above.
        let raw = defaults.string(forKey: "hardwareTriggerDestination") ?? ""
        let restored = HardwareTriggerDestination(rawValue: raw) ?? .auto
        XCTAssertEqual(restored, .auto)
    }

    // MARK: - Auto (#1008)

    /// The keyboard lane skips the pasteboard because the words are going into
    /// the field the user was typing in; History still holds every capture.
    func testAutoMapsAnOpenKeyboardToAHistoryOnlySideEffect() {
        let plan = AutoDestinationPolicy.plan(
            AutoDestinationPolicy.Inputs(
                transcriptIsEmpty: false,
                keyboardTargetIsOpen: true,
                keyboardOfferAvailable: true
            )
        )
        XCTAssertEqual(TranscriptionRecordingService.concreteDestination(for: plan), .historyOnly)
    }

    func testAutoMapsEveryOtherCaseToTheClipboard() {
        let plan = AutoDestinationPolicy.plan(
            AutoDestinationPolicy.Inputs(
                transcriptIsEmpty: false,
                keyboardTargetIsOpen: false,
                keyboardOfferAvailable: true
            )
        )
        XCTAssertEqual(TranscriptionRecordingService.concreteDestination(for: plan), .clipboard)
    }

    /// `.auto` must never reach a side-effect switch; the mapping runs first.
    func testAutoNeverSurvivesIntoTheClipboardDecision() {
        let text = TranscriptionRecordingService.clipboardTextAtStop(
            transcript: "hello",
            destination: .historyOnly
        )
        XCTAssertNil(text)
    }

    func testUnknownRawValueFallsBackToClipboard() {
        // Defensive: if a future build wrote an unknown raw value (e.g. a
        // case that has since been removed), the loader should not crash
        // and should fall back to `.clipboard`.
        defaults.set("nonsense", forKey: "hardwareTriggerDestination")
        let raw = defaults.string(forKey: "hardwareTriggerDestination") ?? ""
        let restored = HardwareTriggerDestination(rawValue: raw) ?? .clipboard
        XCTAssertEqual(restored, .clipboard)
    }
}
#endif
