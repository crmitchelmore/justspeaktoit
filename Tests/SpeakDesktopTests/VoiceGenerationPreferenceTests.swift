import SpeakCore
import XCTest

final class VoiceGenerationPreferenceTests: XCTestCase {
    func testTransferMetadata_UsesCanonicalDefaultsWithoutAddingDictationControls() {
        let fields = DesktopConfiguration.voiceGenerationTransferFields
        XCTAssertEqual(fields.map(\.key), ["ttsAutoPlay", "ttsSaveToDirectory"])
        XCTAssertEqual(fields.map(\.defaultValue), [
            AnyCodable(.bool(SpeechGenerationDefaults.autoPlay)),
            AnyCodable(.bool(SpeechGenerationDefaults.saveToRecordings))
        ])
        XCTAssertTrue(Set(DesktopConfiguration.fields.map(\.key))
            .isDisjoint(with: DesktopConfiguration.voiceGenerationTransferKeys))
    }

    func testTransferredBooleans_RejectCoercionAndPreserveAbsence() throws {
        for preference in VoiceGenerationPreference.allCases {
            XCTAssertNil(try preference.value(in: [:]))
            XCTAssertEqual(try preference.value(in: [preference.rawValue: AnyCodable(.bool(false))]), false)
            for value in [AnyCodable(.int(1)), AnyCodable(.string("false")), AnyCodable(.null)] {
                XCTAssertThrowsError(try preference.value(in: [preference.rawValue: value]))
            }
        }
    }
}
