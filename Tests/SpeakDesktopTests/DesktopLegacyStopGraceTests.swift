import Foundation
import XCTest
import SpeakCore

final class DesktopLegacyStopGraceTests: XCTestCase {
    private let legacyKey = ApplicationPreferenceKey.deepgramStopGracePeriod.rawValue
    private let graceKey = ApplicationPreferenceKey.liveStopGracePeriod.rawValue

    func testLegacyOnlyConfiguration_MigratesValidatedValueAndRetainsOriginal() throws {
        for value in [AnyCodable(.int(0)), AnyCodable(.double(0.35)), AnyCodable(.int(2))] {
            let configuration = try DesktopConfiguration(values: [legacyKey: value])
            XCTAssertEqual(configuration.values[legacyKey], value)
            XCTAssertEqual(configuration.values[graceKey], value)
            XCTAssertEqual(configuration.liveOptions.stopGracePeriod, configuration.number(graceKey))
            let restored = try JSONDecoder().decode(
                DesktopConfiguration.self, from: JSONEncoder().encode(configuration)
            )
            XCTAssertEqual(restored, configuration)
        }
        XCTAssertTrue(DesktopConfiguration.supportedKeys.contains(legacyKey))
    }

    func testCanonicalValueIncludingZero_TakesPrecedenceOverLegacy() throws {
        for value in [AnyCodable(.double(0)), AnyCodable(.double(0.75)), AnyCodable(.int(2))] {
            for legacy in [AnyCodable(.double(1.5)), AnyCodable(.string("opaque legacy value"))] {
                let configuration = try DesktopConfiguration(values: [graceKey: value, legacyKey: legacy])
                XCTAssertEqual(configuration.values[graceKey], value)
                XCTAssertEqual(configuration.values[legacyKey], legacy)
            }
        }
    }

    func testInvalidCanonicalValue_DoesNotFallBackToValidLegacy() {
        for value in [AnyCodable(.null), AnyCodable(.bool(false)), AnyCodable(.double(3))] {
            XCTAssertThrowsError(try DesktopConfiguration(values: [
                graceKey: value, legacyKey: AnyCodable(.double(0.5))
            ]))
        }
    }

    func testInvalidLegacyOnlyValue_IsRejectedWithoutCoercionOrClamping() {
        let invalid: [AnyCodable] = [
            AnyCodable(.null), AnyCodable(.bool(false)), AnyCodable(.string("0.5")),
            AnyCodable(.array([])), AnyCodable(.object([:])),
            AnyCodable(.int(-1)), AnyCodable(.int(3)), AnyCodable(.double(-0.01)),
            AnyCodable(.double(2.01)), AnyCodable(.double(.infinity)), AnyCodable(.double(.nan))
        ]
        for value in invalid {
            XCTAssertThrowsError(try DesktopConfiguration(values: [legacyKey: value]))
        }
    }

    func testAbsentKeys_KeepCanonicalDefaultWithoutCreatingLegacySetting() throws {
        let configuration = try DesktopConfiguration()
        XCTAssertEqual(configuration.number(graceKey), SpeechDefaults.liveStopGracePeriod)
        XCTAssertNil(configuration.values[graceKey])
        XCTAssertNil(configuration.values[legacyKey])
    }

    func testNativeEditAndRelaunch_DoNotResurrectLegacyValue() throws {
        let configuration = try DesktopConfiguration(values: [
            legacyKey: AnyCodable(.double(1.5)),
            "future": AnyCodable(.object(["preserved": .bool(true)]))
        ])
        let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == graceKey })
        for replacement in ["0", "0.25"] {
            var entries = configuration.entries
            entries[index] = replacement
            let edited = try configuration.applying(entries)
            let restored = try JSONDecoder().decode(
                DesktopConfiguration.self, from: JSONEncoder().encode(edited)
            )
            XCTAssertEqual(restored.number(graceKey), try XCTUnwrap(Double(replacement)))
            XCTAssertEqual(restored.liveOptions.stopGracePeriod, try XCTUnwrap(Double(replacement)))
            XCTAssertEqual(restored.values[legacyKey], configuration.values[legacyKey])
            XCTAssertEqual(restored.values["future"], configuration.values["future"])
        }
    }
}
