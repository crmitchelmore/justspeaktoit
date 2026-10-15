import Foundation
import SpeakCore
import XCTest

final class VoiceFavoritePreferenceTests: XCTestCase {
    func testTransfer_PreservesOrderDuplicatesAndUnavailableIDs() throws {
        let ids = ["future/Voice", "deepgram/retired", "future/Voice", ""]
        XCTAssertEqual(try VoiceFavoritePreference.value(in: [
            VoiceFavoritePreference.key: VoiceFavoritePreference.encoded(ids)
        ]), ids)
        XCTAssertNil(try VoiceFavoritePreference.value(in: [:]))
        for invalid in [AnyCodable(.string("voice")), AnyCodable(.array([.string("voice"), .int(1)]))] {
            XCTAssertThrowsError(try VoiceFavoritePreference.value(in: [VoiceFavoritePreference.key: invalid]))
        }
        XCTAssertTrue(DesktopConfiguration.voiceTransferKeys.contains(VoiceFavoritePreference.key))
        XCTAssertEqual(DataMigrationPreferenceCatalog.definition(for: VoiceFavoritePreference.key)?.kind, .stringArray)
    }

    func testProjection_UsesExactCanonicalIDsAndSavedOrderWithoutFallback() throws {
        let voices = Array(DesktopSpeechVoice.voices.prefix(3))
        XCTAssertEqual(voices.count, 3)
        let picker = DesktopVoicePicker(voices: voices + voices, favoriteIDs: [
            voices[2].favoriteIdentifier, "other-provider/retired", voices[0].favoriteIdentifier,
            voices[2].favoriteIdentifier, voices[1].favoriteIdentifier.uppercased()
        ])
        XCTAssertEqual(picker.voices, voices)
        XCTAssertEqual(picker.favoriteIndices, [2, 0])
        XCTAssertEqual(picker.favorites, [true, false, true])
        XCTAssertEqual(picker.voices[picker.favoriteIndices[0]].id, voices[2].id)
        if case .deepgram(let voice) = voices[0] {
            XCTAssertEqual(voices[0].favoriteIdentifier, voice.providerVoiceID)
            XCTAssertNotEqual(voices[0].favoriteIdentifier, voice.id)
        }
    }

    func testEdit_AddIsIdempotentAndRemovePreservesOtherRawMaterial() {
        let old = ["future/id", "voice", "voice", "Retired"]
        XCTAssertEqual(VoiceFavoritePreference.updating(old, voiceID: "voice", favorite: true), old)
        XCTAssertEqual(VoiceFavoritePreference.updating(old, voiceID: "new", favorite: true), old + ["new"])
        XCTAssertEqual(VoiceFavoritePreference.updating(old, voiceID: "voice", favorite: false),
                       ["future/id", "Retired"])
    }

    func testProviderNamespaces_UnprefixedSynthesisIDsNeverBecomeFavorites() {
        for voice in DesktopSpeechVoice.voices {
            if case .deepgram(let deepgram) = voice {
                XCTAssertEqual(voice.favoriteIdentifier, deepgram.providerVoiceID)
                let bare = DesktopVoicePicker(voices: [voice], favoriteIDs: [deepgram.id])
                XCTAssertTrue(bare.favoriteIndices.isEmpty)
                XCTAssertEqual(bare.favorites, [false])
            } else {
                XCTAssertEqual(voice.favoriteIdentifier, voice.id)
            }
        }
    }
}
