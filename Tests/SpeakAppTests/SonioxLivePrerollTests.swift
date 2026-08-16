import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

/// Regression cover for issue #641 on the macOS Soniox path.
///
/// `SwitchingLiveTranscriber` routes `soniox/` models to `SonioxLiveController`
/// → ``SonioxLiveTranscriber``, not the shared `SpeakCore` client, so the
/// pre-roll contract has to hold here too: audio captured between the recording
/// cue and the WebSocket reaching `.running` must be held and replayed rather
/// than dropped.
final class SonioxLivePrerollTests: XCTestCase {

    private func chunk(_ byte: UInt8, count: Int = 3_200) -> Data {
        Data(repeating: byte, count: count)
    }

    func testSoniox_RetainsAudioCapturedBeforeTheTransportIsReady() {
        // Arrange: no `start()`, so there is no running WebSocket — exactly the
        // window between the cue and Soniox's socket handshake completing.
        let transcriber = SonioxLiveTranscriber(apiKey: "k")

        // Act
        transcriber.sendAudio(self.chunk(1))
        transcriber.sendAudio(self.chunk(2))

        // Assert
        XCTAssertEqual(transcriber.preroll.drain(), [self.chunk(1), self.chunk(2)])
    }

    func testSoniox_StopsBufferingOnceTheSessionIsStopping() {
        // Arrange
        let transcriber = SonioxLiveTranscriber(apiKey: "k")
        transcriber.sendAudio(self.chunk(1))

        // Act: stopping without a transport discards what could never be sent
        // and refuses to hold anything for the dead session.
        transcriber.stop()
        transcriber.sendAudio(self.chunk(2))

        // Assert
        XCTAssertTrue(transcriber.preroll.isEmpty)
    }
}
