import Foundation
import XCTest
import SpeakCore
import SpeakDesktop

final class DesktopConfigurationTests: XCTestCase {
    func testClipboardCommandPolicyUsesExistingPreferenceIdentitiesAndRoundTrips() throws {
        let enabled = ApplicationPreferenceKey.voiceCommandsEnabled.rawValue
        let triggers = ApplicationPreferenceKey.clipboardInsertionTriggers.rawValue
        XCTAssertTrue(DesktopConfiguration.supportedKeys.isSuperset(of: [enabled, triggers]))
        let defaults = try DesktopConfiguration().clipboardVoiceCommandPolicy
        XCTAssertEqual(defaults.isEnabled, SpeechDefaults.voiceCommandsEnabled)
        XCTAssertEqual(defaults.customTriggers, "")
        let configured = try DesktopConfiguration(values: [
            enabled: AnyCodable(.bool(false)), triggers: AnyCodable(.string("my snippet, insert context"))
        ])
        let restored = try JSONDecoder().decode(
            DesktopConfiguration.self, from: JSONEncoder().encode(configured.applying(configured.entries))
        )
        XCTAssertEqual(restored.clipboardVoiceCommandPolicy, ClipboardVoiceCommandPolicy(
            isEnabled: false, customTriggers: "my snippet, insert context"
        ))
        XCTAssertEqual(
            try restored.applying(restored.entries).clipboardVoiceCommandPolicy, configured.clipboardVoiceCommandPolicy
        )
    }

    func testClipboardCommandPolicyRejectsWrongTypes() {
        XCTAssertThrowsError(try DesktopConfiguration(values: [
            ApplicationPreferenceKey.voiceCommandsEnabled.rawValue: AnyCodable(.string("true"))
        ]))
        XCTAssertThrowsError(try DesktopConfiguration(values: [
            ApplicationPreferenceKey.clipboardInsertionTriggers.rawValue: AnyCodable(.bool(true))
        ]))
    }

    func testChoiceMetadataIsUnambiguousBoundedAndIncludesItsDefault() {
        for field in DesktopConfiguration.fields {
            guard case .choice(let choices) = field.kind else { continue }
            XCTAssertFalse(choices.isEmpty)
            XCTAssertLessThanOrEqual(choices.count, 32)
            XCTAssertEqual(Set(choices.map(\.value)).count, choices.count)
            for choice in choices {
                for text in [choice.value, choice.title] {
                    XCTAssertFalse(text.isEmpty)
                    XCTAssertFalse(
                        text.contains("\t") || text.contains("\n") || text.contains("\r") || text.contains("\0")
                    )
                }
            }
            XCTAssertLessThanOrEqual(field.serializedChoices?.utf8.count ?? 0, 65_535)
            XCTAssertTrue(choices.contains { AnyCodable(.string($0.value)) == field.defaultValue })
        }
    }

    func testDefaultsAndEveryFieldRoundTrip() throws {
        let defaults = try DesktopConfiguration()
        let restored = try defaults.applying(defaults.entries)
        XCTAssertEqual(restored.entries, defaults.entries)
        XCTAssertNil(restored.language)
        XCTAssertEqual(restored.number("holdThreshold"), HotKeyGestureTiming.defaultHoldThreshold)
        XCTAssertEqual(restored.number("doubleTapWindow"), HotKeyGestureTiming.defaultDoubleTapWindow)
        XCTAssertEqual(restored.number("postProcessingTemperature"), 0.2)
        XCTAssertEqual(restored.number("postRecordingTailDuration"), SpeechDefaults.recordingTailDuration)
        XCTAssertTrue(restored.enabled("showHUD"))
        XCTAssertFalse(restored.enabled("showCompactHUD"))
        XCTAssertEqual(restored.enabled("recordingSoundsEnabled"), RecordingFeedbackDefaults.enabled)
        XCTAssertEqual(restored.text("recordingSoundProfile"), RecordingFeedbackDefaults.profile.rawValue)
        XCTAssertEqual(restored.number("recordingSoundVolume"), RecordingFeedbackDefaults.volume)
        XCTAssertEqual(Set(DesktopConfiguration.fields.map(\.key)).count, DesktopConfiguration.fields.count)
    }

    func testRecordingSoundMetadata_UsesCanonicalProfilesAndSurvivesTransfer() throws {
        let field = try XCTUnwrap(DesktopConfiguration.fields.first { $0.key == "recordingSoundProfile" })
        guard case .choice(let choices) = field.kind else { return XCTFail("Missing recording profile choices.") }
        XCTAssertEqual(choices.map(\.value), RecordingFeedbackProfile.allCases.map(\.rawValue))
        XCTAssertEqual(choices.map(\.title), RecordingFeedbackProfile.allCases.map(\.displayName))
        for profile in RecordingFeedbackProfile.allCases {
            let preferences = try DesktopConfiguration(values: [
                "recordingSoundsEnabled": AnyCodable(.bool(false)),
                "recordingSoundProfile": AnyCodable(.string(profile.rawValue)),
                "recordingSoundVolume": AnyCodable(.double(0.25))
            ])
            let restored = try JSONDecoder().decode(
                DesktopConfiguration.self, from: JSONEncoder().encode(preferences.applying(preferences.entries))
            )
            XCTAssertFalse(restored.enabled("recordingSoundsEnabled"))
            XCTAssertEqual(restored.text("recordingSoundProfile"), profile.rawValue)
            XCTAssertEqual(restored.number("recordingSoundVolume"), 0.25)
        }
    }

    func testOverlayCapabilityMetadataAndCompactValueSurviveTransfer() throws {
        let overlayKeys = Set(DesktopConfiguration.fields.filter(\.requiresHUDOverlay).map(\.key))
        XCTAssertEqual(overlayKeys, [
            "showLiveTranscriptInHUD", "shortenErrorDisplay", "showCompactHUD", "hudSizePreference"
        ])
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
            case .choice(let choices):
                for choice in choices {
                    XCTAssertNoThrow(try DesktopConfiguration(values: [field.key: AnyCodable(.string(choice.value))]))
                }
                XCTAssertThrowsError(try DesktopConfiguration(values: [field.key: AnyCodable(.string("invalid"))]))
                XCTAssertThrowsError(try DesktopConfiguration(values: [field.key: AnyCodable(.int(1))]))
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
        XCTAssertEqual(preferences.liveOptions.keywords, ["Swift", "Speak", "Ada", "Grace"])
        XCTAssertEqual(preferences.liveOptions.assemblyAIKeyterms, ["Swift", "Speak", "Ada", "Grace"])
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
