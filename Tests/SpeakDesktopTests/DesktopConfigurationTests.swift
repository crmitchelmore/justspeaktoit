import Foundation
import XCTest
import SpeakCore
import SpeakDesktop

final class DesktopConfigurationTests: XCTestCase {
    /// Choice fields that intentionally preserve an unrecognized stored string across
    /// transfer instead of rejecting it outright (for example a future Soniox region
    /// identifier, or a speech quality/speed mode this build does not yet recognize),
    /// rather than letting a native combo silently fall back to a default. Any field
    /// key here still goes through the shared canonical overlength/control-character
    /// refusal in `DesktopConfiguration.validateFields`; it is not an unconditional skip.
    private static let forwardCompatibleChoiceKeys: Set<String> = [
        SonioxVoicePreference.regionKey,
        ApplicationPreferenceKey.ttsQuality.rawValue,
        ApplicationPreferenceKey.speedMode.rawValue
    ]

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
                // Forward-compatible choice fields intentionally preserve an unrecognized
                // stored string (e.g. a future region identifier, or quality/speed mode this
                // build does not yet recognize) across transfer instead of rejecting it; see
                // SonioxVoicePreference and Self.forwardCompatibleChoiceKeys. Assert that
                // round-trip acceptance explicitly, and that the shared canonical
                // overlength/control-character refusal still applies rather than accepting
                // every unknown value unconditionally.
                if Self.forwardCompatibleChoiceKeys.contains(field.key) {
                    let accepted = try DesktopConfiguration(values: [field.key: AnyCodable(.string("invalid"))])
                    XCTAssertEqual(accepted.values[field.key], AnyCodable(.string("invalid")))
                    // The unknown string must survive not just construction but an edit/apply
                    // cycle and a full JSON encode/decode round trip, since that is the actual
                    // transfer path a stored preference travels through.
                    let editedAccepted = try accepted.applying(accepted.entries)
                    let restoredAccepted = try JSONDecoder().decode(
                        DesktopConfiguration.self, from: JSONEncoder().encode(editedAccepted)
                    )
                    XCTAssertEqual(restoredAccepted.values[field.key], AnyCodable(.string("invalid")))
                    let maxLength = String(repeating: "a", count: 256)
                    XCTAssertNoThrow(try DesktopConfiguration(values: [field.key: AnyCodable(.string(maxLength))]))
                    let overlength = String(repeating: "a", count: 257)
                    XCTAssertThrowsError(try DesktopConfiguration(values: [field.key: AnyCodable(.string(overlength))]))
                    // The 256-byte bound is a UTF-8 byte count, not a character count: a
                    // multi-byte character must be measured in bytes so this does not regress
                    // to silently counting characters instead.
                    let maxLengthMultibyte = String(repeating: "\u{00E9}", count: 128)
                    XCTAssertEqual(maxLengthMultibyte.utf8.count, 256)
                    XCTAssertNoThrow(
                        try DesktopConfiguration(values: [field.key: AnyCodable(.string(maxLengthMultibyte))])
                    )
                    let overlengthMultibyte = String(repeating: "\u{00E9}", count: 129)
                    XCTAssertEqual(overlengthMultibyte.utf8.count, 258)
                    XCTAssertThrowsError(
                        try DesktopConfiguration(values: [field.key: AnyCodable(.string(overlengthMultibyte))])
                    )
                    XCTAssertThrowsError(
                        try DesktopConfiguration(values: [field.key: AnyCodable(.string("bad\u{0001}control"))])
                    )
                } else {
                    XCTAssertThrowsError(try DesktopConfiguration(values: [field.key: AnyCodable(.string("invalid"))]))
                }
                XCTAssertThrowsError(try DesktopConfiguration(values: [field.key: AnyCodable(.int(1))]))
            }
        }
        var entries = try DesktopConfiguration().entries
        let graceIndex = try XCTUnwrap(DesktopConfiguration.fields.firstIndex {
            $0.key == ApplicationPreferenceKey.liveStopGracePeriod.rawValue
        })
        entries[graceIndex] = "nan"
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
