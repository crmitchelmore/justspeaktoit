import Foundation
import SpeakCore
import XCTest

final class DesktopEscapeCancellationPreferenceTests: XCTestCase {
    private let key = ApplicationPreferenceKey.cancelRecordingOnEscape.rawValue

    func testMissingPreferenceUsesSharedMacDefaultAndHasOneBooleanEditorField() throws {
        let preferences = try DesktopConfiguration()
        XCTAssertTrue(SpeechDefaults.cancelRecordingOnEscape)
        XCTAssertEqual(preferences.cancelRecordingOnEscape, SpeechDefaults.cancelRecordingOnEscape)
        XCTAssertNil(preferences.values[key])
        let fields = DesktopConfiguration.fields.filter { $0.key == key }
        XCTAssertEqual(fields.count, 1)
        let field = try XCTUnwrap(fields.first)
        guard case .boolean = field.kind else { return XCTFail("Escape must be a Boolean preference.") }
        XCTAssertEqual(field.group, "Keyboard")
        XCTAssertEqual(field.defaultValue, AnyCodable(.bool(SpeechDefaults.cancelRecordingOnEscape)))
        XCTAssertLessThanOrEqual(DesktopConfiguration.fields.count, 64)
    }

    func testExplicitValuesSurviveCodableAndEditorRoundTrips() throws {
        for enabled in [false, true] {
            let preferences = try DesktopConfiguration(values: [key: AnyCodable(.bool(enabled))])
            let restored = try JSONDecoder().decode(
                DesktopConfiguration.self, from: JSONEncoder().encode(preferences)
            )
            XCTAssertEqual(restored.cancelRecordingOnEscape, enabled)
            XCTAssertEqual(restored.values[key], AnyCodable(.bool(enabled)))
            let edited = try restored.applying(restored.entries)
            XCTAssertEqual(edited.cancelRecordingOnEscape, enabled)
            XCTAssertEqual(edited.values[key], AnyCodable(.bool(enabled)))
        }
    }

    func testNonBooleanValuesAreRejectedRatherThanSilentlyEnablingCancellation() {
        for value in [
            AnyCodable(.string("false")), AnyCodable(.int(0)),
            AnyCodable(.double(1.0)), AnyCodable(.array([]))
        ] {
            XCTAssertThrowsError(try DesktopConfiguration(values: [key: value]))
        }
    }
}
