import Foundation
import XCTest
import SpeakCore
import SpeakDesktop

final class DesktopConfigurationTests: XCTestCase {
    func testDefaultsAndEveryFieldRoundTrip() throws {
        let defaults = try DesktopConfiguration()
        let restored = try defaults.applying(defaults.entries)
        XCTAssertEqual(restored.entries, defaults.entries)
        XCTAssertNil(restored.language)
        XCTAssertEqual(restored.number("holdThreshold"), HotKeyGestureTiming.defaultHoldThreshold)
        XCTAssertEqual(restored.number("doubleTapWindow"), HotKeyGestureTiming.defaultDoubleTapWindow)
        XCTAssertEqual(restored.number("postProcessingTemperature"), 0.2)
        XCTAssertTrue(restored.enabled("showHUD"))
        XCTAssertFalse(restored.enabled("showCompactHUD"))
        XCTAssertEqual(Set(DesktopConfiguration.fields.map(\.key)).count, DesktopConfiguration.fields.count)
    }

    func testOverlayCapabilityMetadataAndCompactValueSurviveTransfer() throws {
        let overlayKeys = Set(DesktopConfiguration.fields.filter(\.requiresHUDOverlay).map(\.key))
        XCTAssertEqual(overlayKeys, ["showLiveTranscriptInHUD", "shortenErrorDisplay", "showCompactHUD"])
        let preferences = try DesktopConfiguration(values: [
            "showCompactHUD": AnyCodable(.bool(true)),
            "shortenErrorDisplay": AnyCodable(.bool(true)),
            "showLiveTranscriptInHUD": AnyCodable(.bool(false))
        ])
        let restored = try JSONDecoder().decode(
            DesktopConfiguration.self, from: JSONEncoder().encode(preferences.applying(preferences.entries))
        )
        for (key, value) in preferences.values {
            XCTAssertEqual(restored.values[key], value)
        }
        XCTAssertTrue(restored.enabled("showCompactHUD"))
    }

    func testUnknownValuesSurviveEditingAndEncodingWithoutBeingApplied() throws {
        let value = AnyCodable(.object(["engine": .string("apple/local/speech"), "enabled": .bool(true)]))
        let original = try DesktopConfiguration(values: ["future": value])
        let edited = try original.applying(original.entries)
        let restored = try JSONDecoder().decode(
            DesktopConfiguration.self, from: JSONEncoder().encode(edited)
        )
        XCTAssertEqual(restored.values["future"], value)
        XCTAssertNil(restored.language)
    }

    func testNumericRangesTypesAndNonFiniteEntriesAreRejected() throws {
        for field in DesktopConfiguration.fields {
            switch field.kind {
            case .number(let range):
                for number in [range.lowerBound - 0.01, range.upperBound + 0.01, .infinity, .nan] {
                    XCTAssertThrowsError(try DesktopConfiguration(values: [field.key: AnyCodable(.double(number))]))
                }
                for number in [range.lowerBound, range.upperBound] {
                    XCTAssertNoThrow(try DesktopConfiguration(values: [field.key: AnyCodable(.double(number))]))
                }
            case .boolean:
                XCTAssertThrowsError(try DesktopConfiguration(values: [field.key: AnyCodable(.string("true"))]))
            case .text:
                XCTAssertThrowsError(try DesktopConfiguration(values: [field.key: AnyCodable(.int(1))]))
                XCTAssertThrowsError(try DesktopConfiguration(values: [field.key: AnyCodable(.string("bad\0text"))]))
            }
        }
        var entries = try DesktopConfiguration().entries
        entries[3] = "nan"
        XCTAssertThrowsError(try DesktopConfiguration().applying(entries))
        XCTAssertThrowsError(try DesktopConfiguration().applying([]))
    }

    func testLanguageAndVocabularyReachCanonicalOptions() throws {
        let preferences = try DesktopConfiguration(values: [
            "preferredLocale": AnyCodable(.string("en_GB")),
            "transcriptionKeywords": AnyCodable(.string(" Swift, Speak , ")),
            "assemblyAIKeyterms": AnyCodable(.string(" Ada , Grace, ")),
            "liveStopGracePeriod": AnyCodable(.double(0.5))
        ])
        XCTAssertEqual(preferences.language, "en_GB")
        XCTAssertEqual(preferences.liveOptions.keywords, ["Swift", "Speak"])
        XCTAssertEqual(preferences.liveOptions.assemblyAIKeyterms, ["Ada", "Grace"])
        XCTAssertEqual(preferences.liveOptions.stopGracePeriod, 0.5)
    }

    func testProfilesInheritGlobalLanguageAndAutomaticOverridesIt() {
        let model = DesktopTranscription.batchModels[0].id
        var profile = DictationProfile(name: "Test")
        let inherited = DesktopProfileSessionResolver.resolve(
            profile: profile, defaultModel: model, defaultPostProcessing: .init(),
            capabilities: .shared, defaultLanguage: "fr_FR"
        )
        XCTAssertEqual(inherited.language, "fr_FR")
        profile.languageIdentifier = "automatic"
        let automatic = DesktopProfileSessionResolver.resolve(
            profile: profile, defaultModel: model, defaultPostProcessing: .init(),
            capabilities: .shared, defaultLanguage: "fr_FR"
        )
        XCTAssertNil(automatic.language)
    }
}
