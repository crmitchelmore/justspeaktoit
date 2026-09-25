import XCTest
import SpeakCore
@testable import SpeakDesktop

final class ElevenLabsDesktopRouteTests: XCTestCase {
    /// The canonical ElevenLabs Scribe v2 live route flows through the shared
    /// desktop factory to the shared `ElevenLabsLiveClient`, and the Windows
    /// executable projection (a filter over the same `liveModels`) follows it
    /// automatically — no Windows-owned list is edited to add a route.
    func testElevenLabsScribeV2IsAProjectedLiveRouteAndSelectsTheSharedClient() throws {
        let modelID = "elevenlabs/scribe-v2-streaming"
        let option = try XCTUnwrap(ModelCatalog.liveTranscription.first { $0.id == modelID })
        XCTAssertTrue(DesktopLiveTranscription.liveModels.contains { $0.id == option.id },
                      "The canonical ElevenLabs live model must be a projected desktop route")

        let route = try XCTUnwrap(DesktopLiveTranscription.route(forID: modelID))
        XCTAssertEqual(route.provider, .elevenlabs)
        XCTAssertEqual(route.apiModelName, "scribe_v2_realtime")
        XCTAssertEqual(route.sampleRate, LiveTranscriptionProviderID.elevenlabs.expectedSampleRate)

        let provider = try XCTUnwrap(DesktopLiveTranscription.provider(forID: modelID))
        XCTAssertEqual(provider.id, LiveTranscriptionProviderID.elevenlabs.rawValue)
        XCTAssertEqual(provider.apiKeyIdentifier, route.apiKeyIdentifier)

        let client = DesktopLiveTranscription.makeClient(model: modelID, apiKey: "k", language: "en") { _ in
            fatalError("Constructing a client must not open a connection")
        }
        XCTAssertTrue(client is ElevenLabsLiveClient)
        XCTAssertEqual(client?.finalShape, .standaloneSegments)
        XCTAssertEqual(client?.finishFlushesBufferedAudio, true)
    }
}
