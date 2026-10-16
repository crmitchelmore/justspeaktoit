import Foundation
import SpeakCore
import XCTest

final class VoiceSynthesisPreferenceTests: XCTestCase {
    func testMetadata_UsesPublishedBoundsDefaultsAndCanonicalKeysWithoutNativeRows() {
        let fields = DesktopConfiguration.voiceSynthesisTransferFields
        XCTAssertEqual(fields.map(\.key), [
            ApplicationPreferenceKey.ttsSpeed.rawValue, ApplicationPreferenceKey.ttsPitch.rawValue,
            ApplicationPreferenceKey.ttsUseSSML.rawValue
        ])
        XCTAssertEqual(fields.map(\.defaultValue), [
            AnyCodable(.double(VoiceSynthesisOptions.defaultSpeed)),
            AnyCodable(.double(VoiceSynthesisOptions.defaultPitch)),
            AnyCodable(.bool(VoiceSynthesisOptions.defaultUseSSML))
        ])
        guard case .number(let speed) = fields[0].kind, case .number(let pitch) = fields[1].kind else {
            return XCTFail("Numeric synthesis metadata missing.")
        }
        XCTAssertEqual(speed, VoiceSynthesisOptions.speedRange)
        XCTAssertEqual(pitch, VoiceSynthesisOptions.pitchRange)
        // Scoped to the synthesis-only transfer keys this test covers (speed/pitch/SSML),
        // not the broader voiceTransferKeys: Soniox's region/language keys are
        // intentionally both native settings rows and voice-owned transfer keys.
        XCTAssertTrue(Set(DesktopConfiguration.fields.map(\.key))
            .isDisjoint(with: DesktopConfiguration.voiceSynthesisTransferKeys))
    }

    func testUpdate_PreservesAbsenceAndAcceptsExactNumericBoundaries() throws {
        let absent = try VoiceSynthesisPreferenceUpdate(preferences: [:])
        XCTAssertNil(absent.speed)
        XCTAssertNil(absent.pitch)
        XCTAssertNil(absent.useSSML)
        for (speed, pitch) in [(0.5, -12.0), (2.0, 12.0)] {
            let update = try VoiceSynthesisPreferenceUpdate(preferences: [
                "ttsSpeed": AnyCodable(.double(speed)), "ttsPitch": AnyCodable(.double(pitch)),
                "ttsUseSSML": AnyCodable(.bool(true))
            ])
            XCTAssertEqual(update.speed, speed)
            XCTAssertEqual(update.pitch, pitch)
            XCTAssertEqual(update.useSSML, true)
        }
        let integer = try VoiceSynthesisPreferenceUpdate(preferences: ["ttsSpeed": AnyCodable(.int(1))])
        XCTAssertEqual(integer.speed, 1)
    }

    func testUpdate_RejectsCoercionNonfiniteBoundsAndFractionalPitch() {
        let invalid: [(String, AnyCodable)] = [
            ("ttsSpeed", AnyCodable(.bool(true))), ("ttsSpeed", AnyCodable(.string("1"))),
            ("ttsSpeed", AnyCodable(.double(.infinity))), ("ttsSpeed", AnyCodable(.double(.nan))),
            ("ttsSpeed", AnyCodable(.double(0.49))), ("ttsSpeed", AnyCodable(.double(2.01))),
            ("ttsPitch", AnyCodable(.double(-13))), ("ttsPitch", AnyCodable(.double(12.1))),
            ("ttsPitch", AnyCodable(.double(0.5))), ("ttsUseSSML", AnyCodable(.int(1))),
            ("ttsUseSSML", AnyCodable(.string("true"))), ("ttsUseSSML", AnyCodable(.null))
        ]
        for (key, value) in invalid {
            XCTAssertThrowsError(try VoiceSynthesisPreferenceUpdate(preferences: [key: value]), key)
        }
    }

    func testShapeValidation_IsSeparateFromProviderExecutionAdmission() throws {
        let options = try VoiceSynthesisOptions(speed: 1.25, pitch: -2, useSSML: true)
        XCTAssertNoThrow(try options.validate(for: .azureNeural))
        XCTAssertThrowsError(try options.validate(for: .naturalSpeech)) {
            XCTAssertEqual($0 as? VoiceSynthesisConfigurationError, .unsupportedControls)
        }
        XCTAssertNoThrow(try VoiceSynthesisOptions().validate(for: .naturalSpeech))
        for data in [
            #"{"speed":1,"pitch":0.5,"useSSML":false}"#,
            #"{"speed":true,"pitch":0,"useSSML":false}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(VoiceSynthesisOptions.self, from: Data(data.utf8)))
        }
    }
}
