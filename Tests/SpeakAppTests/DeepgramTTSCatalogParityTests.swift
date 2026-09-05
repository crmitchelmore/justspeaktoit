import SpeakCore
import XCTest
@testable import SpeakApp

final class DeepgramTTSCatalogParityTests: XCTestCase {
    func testMacVoiceProjection_MatchesEverySharedDeepgramVoice() {
        XCTAssertEqual(
            Set(VoiceCatalog.deepgramVoices.map(\.id)),
            Set(DeepgramSpeechCatalog.voices.map(\.providerVoiceID))
        )
    }

    func testMacVoiceProjection_PreservesSharedMetadata() throws {
        let shared = try XCTUnwrap(DeepgramTTSCatalog.voice(forID: "aura-2-amalthea-en"))
        let projected = try XCTUnwrap(
            VoiceCatalog.deepgramVoices.first { $0.id == shared.providerVoiceID }
        )

        XCTAssertTrue(projected.name.contains(shared.name))
        XCTAssertTrue(projected.traits.contains(.female))
        XCTAssertTrue(projected.traits.contains(.filipino))
        XCTAssertTrue(projected.traits.contains(.lowLatency))
    }
}
