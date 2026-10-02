import Foundation
import XCTest
@testable import SpeakCore
@testable import SpeakDesktop

extension DesktopLiveSessionTests {
    /// The canonical Soniox live route resolves through the shared factory to the
    /// shared `SonioxLiveClient`, and the Windows model projection is derived
    /// from `DesktopLiveTranscription.liveModels`, so it follows automatically.
    func testCanonicalSonioxLiveRouteIsSelectedAndWindowsProjectionFollowsIt() throws {
        let sonioxID = "soniox/stt-rt-v5-streaming"
        let route = try XCTUnwrap(DesktopLiveTranscription.route(forID: sonioxID))
        XCTAssertEqual(route.provider, .soniox)
        XCTAssertEqual(route.apiModelName, "stt-rt-v5")
        XCTAssertEqual(route.sampleRate, 16_000)
        XCTAssertEqual(route.apiKeyIdentifier, "soniox.apiKey")

        // The desktop live projection — the exact list the Windows host renders
        // through `WindowsModels.live` — now carries the canonical Soniox model.
        XCTAssertTrue(DesktopLiveTranscription.liveModels.contains { $0.id == sonioxID })

        let client = DesktopLiveTranscription.makeClient(
            model: sonioxID, apiKey: "key", language: "fr_FR", makeConnection: { _ in
                fatalError("Constructing a client must not open a connection")
            }
        )
        XCTAssertTrue(client is SonioxLiveClient)
        XCTAssertEqual(client?.finalShape, .cumulativeTranscript)
        XCTAssertEqual(client?.finishFlushesBufferedAudio, true)

        let provider = try XCTUnwrap(DesktopLiveTranscription.provider(forID: sonioxID))
        XCTAssertEqual(provider.id, "soniox")
        XCTAssertEqual(provider.apiKeyIdentifier, "soniox.apiKey")
    }
}
