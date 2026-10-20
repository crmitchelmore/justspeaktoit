import Foundation
import SpeakCore
import XCTest

final class LivePolishPreferenceTests: XCTestCase {
    func testDefaultsAndNativeFields_UseCanonicalKeysAndNoTailWindowControl() throws {
        let configuration = try DesktopConfiguration()
        let options = try configuration.livePolishPreferences
        XCTAssertEqual(options.mode, .instant)
        XCTAssertEqual(options.debounceMilliseconds, 500)
        XCTAssertEqual(options.minimumDeltaCharacters, 20)
        XCTAssertTrue(options.skipPostProcessing)
        XCTAssertEqual(LivePolishPolicy.tailWindowCharacters, 600)
        XCTAssertEqual(LivePolishPreference.keys, [
            "speedMode", "livePolishModel", "livePolishDebounceMs", "livePolishMinDeltaChars",
            "skipPostProcessingWithLivePolish"
        ])
        XCTAssertFalse(DesktopConfiguration.fields.contains { $0.key == "livePolishTailWindowChars" })
        XCTAssertTrue(LivePolishPreference.fields.allSatisfy { $0.group == "Transcription" })
        XCTAssertEqual(Set(DesktopConfiguration.fields.map(\.key)).count, DesktopConfiguration.fields.count)
        XCTAssertLessThanOrEqual(DesktopConfiguration.fields.count, 64, "Both native editors bound fields to 64")
    }

    func testModelResolution_UsesConfiguredThenProfileThenFastDefaultWithoutNormalizingUnknownIDs() {
        XCTAssertEqual(LivePolishPolicy.model(configured: " custom/id ", postProcessing: "profile/id"), "custom/id")
        XCTAssertEqual(LivePolishPolicy.model(configured: " \n", postProcessing: " profile/id "), "profile/id")
        XCTAssertEqual(
            LivePolishPolicy.model(configured: "", postProcessing: ""), ModelCatalog.defaultFastTextModel
        )
    }

    func testNativeEditorAndCodable_RetainUnknownAndDormantTailValues() throws {
        let original = try DesktopConfiguration(values: [
            "speedMode": AnyCodable(.string("future-speed")),
            "livePolishTailWindowChars": AnyCodable(.int(321)),
            "future": AnyCodable(.array([.string("kept")]))
        ])
        XCTAssertThrowsError(try original.livePolishPreferences)
        let speed = try XCTUnwrap(DesktopConfiguration.fields.first { $0.key == "speedMode" })
        XCTAssertTrue(original.serializedChoices(for: speed)?.contains("future-speed\tUnsupported") == true)
        let edited = try original.applying(original.entries)
        let restored = try JSONDecoder().decode(DesktopConfiguration.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(restored, edited)
        XCTAssertEqual(restored.values["speedMode"], original.values["speedMode"])
        XCTAssertEqual(restored.values["livePolishTailWindowChars"], AnyCodable(.int(321)))
        XCTAssertEqual(restored.values["future"], original.values["future"])
    }

    func testTimingValidation_RejectsFractionsNegativeNonFiniteAndWrongTypes() throws {
        for (key, value) in [
            ("livePolishDebounceMs", AnyCodable(.double(0.5))),
            ("livePolishMinDeltaChars", AnyCodable(.double(1.5))),
            ("livePolishDebounceMs", AnyCodable(.int(-1))),
            ("livePolishMinDeltaChars", AnyCodable(.double(.infinity))),
            ("skipPostProcessingWithLivePolish", AnyCodable(.string("true")))
        ] {
            XCTAssertThrowsError(try DesktopConfiguration(values: [key: value]), key)
        }
        let zero = try DesktopConfiguration(values: [
            "livePolishDebounceMs": AnyCodable(.int(0)), "livePolishMinDeltaChars": AnyCodable(.int(0))
        ])
        XCTAssertEqual(try zero.livePolishPreferences.debounceMilliseconds, 0)
    }

    func testUnicodeDeltaPolicy_UsesCharactersAndRecognizesEditsRetractionsAndSilence() {
        let original = "Cafe\u{301} 👩🏽‍💻 words"
        XCTAssertFalse(LivePolishPolicy.shouldRequest(original, after: original, minimumDelta: 20))
        XCTAssertFalse(LivePolishPolicy.shouldRequest(original + "👩🏽‍💻", after: original, minimumDelta: 2))
        XCTAssertTrue(LivePolishPolicy.shouldRequest(original + "👩🏽‍💻👍", after: original, minimumDelta: 2))
        XCTAssertTrue(LivePolishPolicy.shouldRequest("Cafe\u{301} 👩🏽‍💻 Words", after: original, minimumDelta: 200))
        XCTAssertTrue(LivePolishPolicy.shouldRequest("Cafe\u{301}", after: original, minimumDelta: 200))
        XCTAssertFalse(LivePolishPolicy.shouldRequest(" \n ", after: original, minimumDelta: 0))
    }
}
