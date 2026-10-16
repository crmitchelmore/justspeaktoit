import Foundation
import SpeakCore
import XCTest

final class DesktopConfigurationNumericRoundTripTests: XCTestCase {
    func testNumericDefaults_KeepExactNativeEntriesThroughApplyAndJSON() throws {
        let defaults = try DesktopConfiguration()
        let applied = try defaults.applying(defaults.entries)
        let restored = try JSONDecoder().decode(DesktopConfiguration.self, from: JSONEncoder().encode(applied))
        XCTAssertEqual(applied.entries, defaults.entries)
        XCTAssertEqual(restored.entries, defaults.entries)
        XCTAssertEqual(restored, applied)
        for field in DesktopConfiguration.fields {
            guard case .number = field.kind else { continue }
            guard case .double = field.defaultValue.storage else {
                return XCTFail("Numeric default is not canonical: \(field.key)")
            }
        }
        let debounce = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == "livePolishDebounceMs" })
        let delta = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == "livePolishMinDeltaChars" })
        XCTAssertEqual(defaults.entries[debounce], "500.0")
        XCTAssertEqual(defaults.entries[delta], "20.0")
        XCTAssertEqual(try restored.livePolishPreferences, try defaults.livePolishPreferences)
    }

    func testKnownNumericIntegers_NormalizeBeforeNativeAndCodableRoundTrips() throws {
        let numbers: [String: Int] = [
            "livePolishDebounceMs": 500, "livePolishMinDeltaChars": 20,
            "liveStopGracePeriod": 0, "silenceDuration": 2, "postProcessingTemperature": 1
        ]
        let integers = try DesktopConfiguration(values: numbers.mapValues { AnyCodable(.int($0)) })
        let doubles = try DesktopConfiguration(values: numbers.mapValues { AnyCodable(.double(Double($0))) })
        XCTAssertEqual(integers, doubles)
        for (key, value) in numbers {
            XCTAssertEqual(integers.values[key], AnyCodable(.double(Double(value))))
        }
        let decoded = try JSONDecoder().decode(DesktopConfiguration.self, from: JSONEncoder().encode(integers))
        XCTAssertEqual(decoded, integers)
        let applied = try integers.applying(integers.entries)
        let restored = try JSONDecoder().decode(DesktopConfiguration.self, from: JSONEncoder().encode(applied))
        XCTAssertEqual(restored, applied)
        XCTAssertEqual(try restored.livePolishPreferences, try integers.livePolishPreferences)
    }

    func testNumericNormalization_PreservesUnknownDormantAndAbsentPreferences() throws {
        let retained: [String: AnyCodable] = [
            "speedMode": AnyCodable(.string("future-speed")),
            "livePolishTailWindowChars": AnyCodable(.int(321)),
            "futureNumber": AnyCodable(.int(Int.max)),
            "futureText": AnyCodable(.string("500")),
            "futureObject": AnyCodable(.object(["integer": .int(20), "text": .string("20.0")])),
            "ttsPitch": AnyCodable(.int(-3))
        ]
        let original = try DesktopConfiguration(values: retained)
        XCTAssertNil(original.values["livePolishDebounceMs"])
        XCTAssertNil(original.values["livePolishMinDeltaChars"])
        for (key, value) in retained { XCTAssertEqual(original.values[key], value, key) }
        let applied = try original.applying(original.entries)
        let restored = try JSONDecoder().decode(DesktopConfiguration.self, from: JSONEncoder().encode(applied))
        XCTAssertEqual(restored, applied)
        for (key, value) in retained { XCTAssertEqual(restored.values[key], value, key) }
        XCTAssertThrowsError(try restored.livePolishPreferences)
    }

    func testWholeNumberBounds_AcceptNativeDecimalSpellingAndRetainExactPreferences() throws {
        for (debounce, delta) in [(0, 0), (60_000, 65_535)] {
            let original = try DesktopConfiguration(values: [
                "livePolishDebounceMs": AnyCodable(.int(debounce)),
                "livePolishMinDeltaChars": AnyCodable(.int(delta))
            ])
            let applied = try original.applying(original.entries)
            let restored = try JSONDecoder().decode(DesktopConfiguration.self, from: JSONEncoder().encode(applied))
            XCTAssertEqual(restored, applied)
            XCTAssertEqual(try restored.livePolishPreferences.debounceMilliseconds, debounce)
            XCTAssertEqual(try restored.livePolishPreferences.minimumDeltaCharacters, delta)
        }
    }

    func testNumericNormalization_RejectsInvalidInputWithoutMutatingTheOriginal() throws {
        let original = try DesktopConfiguration(values: ["livePolishDebounceMs": AnyCodable(.int(123))])
        let before = try JSONEncoder().encode(original)
        for (key, value) in [
            ("livePolishDebounceMs", AnyCodable(.string("500"))),
            ("livePolishMinDeltaChars", AnyCodable(.bool(true))),
            ("livePolishDebounceMs", AnyCodable(.double(0.5))),
            ("livePolishMinDeltaChars", AnyCodable(.double(1.5))),
            ("livePolishDebounceMs", AnyCodable(.int(60_001))),
            ("livePolishMinDeltaChars", AnyCodable(.int(65_536))),
            ("livePolishDebounceMs", AnyCodable(.int(-1)))
        ] {
            XCTAssertThrowsError(try DesktopConfiguration(values: [key: value]), key)
        }
        let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == "livePolishDebounceMs" })
        for invalid in ["0.5", "-1", "60001", "not a number", "nan", "inf"] {
            var entries = original.entries
            entries[index] = invalid
            XCTAssertThrowsError(try original.applying(entries), invalid)
        }
        let restored = try JSONDecoder().decode(DesktopConfiguration.self, from: before)
        XCTAssertEqual(original, restored)
        XCTAssertEqual(original.values["livePolishDebounceMs"], AnyCodable(.double(123)))
    }
}
