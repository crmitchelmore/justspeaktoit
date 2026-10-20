import SpeakCore
import XCTest
@testable import SpeakApp

final class ElevenLabsSharedCatalogTests: XCTestCase {
    func testMacPresetsTraitsAndCredential_AreExactSharedProjections() {
        XCTAssertEqual(VoiceCatalog.elevenlabsVoices.map(\.id),
                       ElevenLabsTTSCatalog.voices.map(\.providerVoiceID))
        XCTAssertEqual(VoiceCatalog.elevenlabsVoices.map(\.name),
                       ElevenLabsTTSCatalog.voices.map(\.displayName))
        XCTAssertEqual(VoiceCatalog.elevenlabsVoices.map { $0.traits.map(\.rawValue) },
                       ElevenLabsTTSCatalog.voices.map { $0.traits.map(\.rawValue) })
        XCTAssertTrue(VoiceCatalog.elevenlabsVoices.allSatisfy { $0.provider == .elevenlabs })
        XCTAssertEqual(TTSProvider.elevenlabs.apiKeyIdentifier, ElevenLabsTTSCatalog.credentialIdentifier)
        XCTAssertEqual(ElevenLabsTTSModels.all.map(\.id),
                       ["eleven_v4", "eleven_v3", "eleven_multilingual_v2", "eleven_flash_v2_5"])
        XCTAssertEqual(ElevenLabsTTSModels.all.map(\.maximumCharacters), [10_000, 5_000, 10_000, 40_000])
    }
}
