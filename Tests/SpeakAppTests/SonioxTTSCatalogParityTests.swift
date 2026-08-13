import SpeakCore
import XCTest
@testable import SpeakApp

final class SonioxTTSCatalogParityTests: XCTestCase {
    func testMacVoiceProjection_MatchesEverySharedSonioxVoice() {
        XCTAssertEqual(
            Set(VoiceCatalog.sonioxVoices.map(\.id)),
            Set(SonioxTTSCatalog.voices.map(\.providerVoiceID))
        )
    }

    func testMacVoiceProjection_PreservesSharedMetadata() throws {
        let shared = try XCTUnwrap(SonioxTTSCatalog.voice(forID: "Arjun"))
        let projected = try XCTUnwrap(
            VoiceCatalog.sonioxVoices.first { $0.id == shared.providerVoiceID }
        )

        XCTAssertEqual(projected.name, shared.id)
        XCTAssertEqual(projected.provider, .soniox)
        XCTAssertTrue(projected.traits.contains(.male))
        XCTAssertTrue(projected.traits.contains(.indian))
        XCTAssertTrue(projected.traits.contains(.multilingual))
    }

    func testEverySonioxVoice_RoutesBackToTheSonioxProvider() {
        for voice in VoiceCatalog.sonioxVoices {
            XCTAssertEqual(TTSProvider.from(voiceID: voice.id), .soniox)
            XCTAssertNotNil(VoiceCatalog.voice(forID: voice.id))
        }
    }

    func testSonioxSharesItsTranscriptionCredential() {
        XCTAssertEqual(TTSProvider.soniox.apiKeyIdentifier, "soniox.apiKey")
        XCTAssertTrue(TTSProvider.soniox.sharesTranscriptionCredential)
        XCTAssertTrue(TTSProvider.soniox.requiresAPIKey)
    }

    func testVoiceOutputLanguageAndRegionDefaults_AreIndependentFromTranscription() {
        XCTAssertEqual(VoiceOutputLanguageCatalog.normalizedIdentifier(nil), "automatic")
        XCTAssertEqual(SonioxTTSRegion.migrated(from: nil), .unitedStates)
    }
}
