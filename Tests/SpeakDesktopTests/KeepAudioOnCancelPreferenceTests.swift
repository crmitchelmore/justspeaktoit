import Foundation
import SpeakCore
import XCTest

final class KeepAudioOnCancelPreferenceTests: XCTestCase {
    private let key = ApplicationPreferenceKey.keepAudioOnCancel.rawValue

    func testMissingPreferenceKeepsAudioAndHasOneGeneralBooleanField() throws {
        let preferences = try DesktopConfiguration()
        XCTAssertTrue(SpeechDefaults.keepAudioOnCancel)
        XCTAssertTrue(preferences.keepAudioOnCancel)
        XCTAssertNil(preferences.values[key])
        let field = try XCTUnwrap(DesktopConfiguration.fields.first { $0.key == key })
        guard case .boolean = field.kind else { return XCTFail("Keep audio must be a Boolean preference.") }
        XCTAssertEqual(field.group, "General")
        XCTAssertEqual(field.defaultValue, AnyCodable(.bool(true)))
        XCTAssertLessThanOrEqual(DesktopConfiguration.fields.count, 64)
    }

    func testExplicitValuesSurviveCodableEditorAndMigrationCatalogue() throws {
        for enabled in [false, true] {
            let preferences = try DesktopConfiguration(values: [key: AnyCodable(.bool(enabled))])
            let restored = try JSONDecoder().decode(
                DesktopConfiguration.self, from: JSONEncoder().encode(preferences)
            )
            XCTAssertEqual(try restored.applying(restored.entries).keepAudioOnCancel, enabled)
        }
        let definition = try XCTUnwrap(DataMigrationPreferenceCatalog.definition(for: key))
        XCTAssertEqual(definition.category, .settings)
        XCTAssertThrowsError(try DesktopConfiguration(values: [key: AnyCodable(.string("false"))]))
    }
}
