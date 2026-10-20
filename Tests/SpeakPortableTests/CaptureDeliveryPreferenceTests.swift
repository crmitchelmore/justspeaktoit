import Foundation
import SpeakCore
import XCTest

final class CaptureDeliveryPreferenceTests: XCTestCase {
    func testFields_UseMacKeysDefaultsAndPortableGroups() throws {
        XCTAssertEqual(CaptureDeliveryPreference.fields.map(\.key), [
            "audioPreWarmingEnabled", "warmMicrophoneOnKeyPress", "streamingInsertionEnabled",
            "pasteRemoteTranscriptsAtCursor", "historyFlushInterval"
        ])
        let configuration = try DesktopConfiguration()
        XCTAssertTrue(configuration.audioPreWarmingEnabled)
        XCTAssertTrue(configuration.warmMicrophoneOnKeyPress)
        XCTAssertFalse(configuration.enabled("streamingInsertionEnabled"))
        XCTAssertFalse(configuration.pasteRemoteTranscriptsAtCursor)
        XCTAssertEqual(configuration.number("historyFlushInterval"), 5)
        let keys = DesktopConfiguration.fields.map(\.key)
        let start = try XCTUnwrap(keys.firstIndex(of: "audioPreWarmingEnabled"))
        XCTAssertEqual(
            Array(keys.dropFirst(start).prefix(CaptureDeliveryPreference.fields.count)),
            CaptureDeliveryPreference.fields.map(\.key)
        )
        XCTAssertTrue(CaptureDeliveryPreference.keys.isSubset(of: DesktopConfiguration.supportedKeys))
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertLessThanOrEqual(keys.count, 64, "Both native editors bound fields to 64")
    }

    func testValues_RoundTripThroughEditorEntriesAndCodable() throws {
        let imported = try DesktopConfiguration(values: [
            "audioPreWarmingEnabled": AnyCodable(.bool(false)),
            "warmMicrophoneOnKeyPress": AnyCodable(.bool(false)),
            "streamingInsertionEnabled": AnyCodable(.bool(true)),
            "pasteRemoteTranscriptsAtCursor": AnyCodable(.bool(true)),
            "historyFlushInterval": AnyCodable(.int(12))
        ])
        let edited = try imported.applying(imported.entries)
        let restored = try JSONDecoder().decode(DesktopConfiguration.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(restored, edited)
        XCTAssertFalse(restored.audioPreWarmingEnabled)
        XCTAssertFalse(restored.warmMicrophoneOnKeyPress)
        XCTAssertTrue(restored.enabled("streamingInsertionEnabled"))
        XCTAssertTrue(restored.pasteRemoteTranscriptsAtCursor)
        XCTAssertEqual(restored.number("historyFlushInterval"), 12)
    }

    func testValidation_RejectsWrongTypesAndOutOfRangeFlushInterval() {
        for (key, value) in [
            ("audioPreWarmingEnabled", AnyCodable(.string("true"))),
            ("pasteRemoteTranscriptsAtCursor", AnyCodable(.int(1))),
            ("historyFlushInterval", AnyCodable(.double(31))),
            ("historyFlushInterval", AnyCodable(.double(-1))),
            ("historyFlushInterval", AnyCodable(.string("5")))
        ] {
            XCTAssertThrowsError(try DesktopConfiguration(values: [key: value]), key)
        }
    }
}
