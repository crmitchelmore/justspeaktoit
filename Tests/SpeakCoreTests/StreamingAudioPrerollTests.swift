import Foundation
import XCTest

@testable import SpeakCore

/// Regression cover for issue #641 — the second half of "clipped initial
/// speech".
///
/// Even once the microphone tap is live, a streaming provider's WebSocket is
/// usually still connecting. Deepgram, ElevenLabs and Soniox used to *discard*
/// every PCM chunk that arrived before the socket reached `.running`, so the
/// opening words were captured by the audio engine and then thrown away in the
/// client. The pre-roll buffer holds that audio and replays it, in order, on
/// the first send that finds a live transport.
final class StreamingAudioPrerollTests: XCTestCase {

    private func chunk(_ byte: UInt8, count: Int = 3_200) -> Data {
        Data(repeating: byte, count: count)
    }

    // MARK: - Buffer behaviour

    func testPreroll_ReplaysPreConnectionAudioInCaptureOrder() {
        // Arrange
        let preroll = StreamingAudioPreroll(sampleRate: 16_000)

        // Act
        preroll.append(self.chunk(1))
        preroll.append(self.chunk(2))
        preroll.append(self.chunk(3))
        let replayed = preroll.drain()

        // Assert
        XCTAssertEqual(replayed, [self.chunk(1), self.chunk(2), self.chunk(3)])
        XCTAssertTrue(preroll.isEmpty)
    }

    func testPreroll_KeepsTheMostRecentAudioWithinItsBudget() {
        // Arrange: 0.2s of 16kHz PCM16 == 6,400 bytes == two 100ms chunks.
        let preroll = StreamingAudioPreroll(sampleRate: 16_000, seconds: 0.2)

        // Act
        preroll.append(self.chunk(1))
        preroll.append(self.chunk(2))
        preroll.append(self.chunk(3))

        // Assert: the oldest chunk is dropped, never the newest, so the audio
        // closest to the connection remains contiguous.
        XCTAssertEqual(preroll.snapshot.byteCount, 6_400)
        XCTAssertEqual(preroll.snapshot.droppedChunkCount, 1)
        XCTAssertEqual(preroll.drain(), [self.chunk(2), self.chunk(3)])
    }

    func testPreroll_DefaultBudgetCoversTypicalConnectionSetup() {
        // Arrange: 5s at 16kHz PCM16.
        let preroll = StreamingAudioPreroll(sampleRate: 16_000)

        // Act
        for index in 0..<10 {
            preroll.append(self.chunk(UInt8(index)))
        }

        // Assert
        XCTAssertEqual(preroll.snapshot.chunkCount, 10)
        XCTAssertEqual(preroll.snapshot.droppedChunkCount, 0)
    }

    func testPreroll_ResetDiscardsBufferedAudioAndCounters() {
        // Arrange
        let preroll = StreamingAudioPreroll(sampleRate: 16_000, seconds: 0.1)
        preroll.append(self.chunk(1))
        preroll.append(self.chunk(2))

        // Act
        preroll.reset()

        // Assert
        XCTAssertTrue(preroll.isEmpty)
        XCTAssertEqual(preroll.snapshot, StreamingAudioPreroll.Snapshot(
            chunkCount: 0, byteCount: 0, droppedChunkCount: 0
        ))
    }

    func testPreroll_IgnoresZeroLengthChunks() {
        // Arrange
        let preroll = StreamingAudioPreroll(sampleRate: 16_000)

        // Act
        preroll.append(Data())

        // Assert
        XCTAssertTrue(preroll.isEmpty)
    }

    // MARK: - Provider contract

    func testDeepgram_RetainsAudioCapturedBeforeTheTransportIsReady() {
        // Arrange: no `start()`, so there is no running WebSocket — exactly the
        // window between the cue and Deepgram's socket handshake completing.
        let client = DeepgramLiveClient(apiKey: "k", model: "nova-3")

        // Act
        client.sendAudio(self.chunk(1))
        client.sendAudio(self.chunk(2))

        // Assert
        XCTAssertEqual(client.preroll.drain(), [self.chunk(1), self.chunk(2)])
    }

    func testElevenLabs_RetainsAudioCapturedBeforeTheTransportIsReady() {
        // Arrange
        let client = ElevenLabsLiveClient(apiKey: "k")

        // Act
        client.sendAudio(self.chunk(1))
        client.sendAudio(self.chunk(2))

        // Assert
        XCTAssertEqual(client.preroll.drain(), [self.chunk(1), self.chunk(2)])
    }

    func testSoniox_RetainsAudioCapturedBeforeTheTransportIsReady() {
        // Arrange
        let client = SonioxLiveClient(apiKey: "k")

        // Act
        client.sendAudio(self.chunk(1))
        client.sendAudio(self.chunk(2))

        // Assert
        XCTAssertEqual(client.preroll.drain(), [self.chunk(1), self.chunk(2)])
    }

    func testDeepgram_StopsBufferingOnceTheSessionIsStopping() {
        // Arrange
        let client = DeepgramLiveClient(apiKey: "k", model: "nova-3")

        // Act: a stop with no live socket still latches the stopping state, so
        // late tap callbacks must not grow the buffer for a dead session.
        client.stop()
        client.sendAudio(self.chunk(1))

        // Assert
        XCTAssertTrue(client.preroll.isEmpty)
    }

    func testSoniox_StopsBufferingOnceTheSessionIsStopping() {
        // Arrange
        let client = SonioxLiveClient(apiKey: "k")
        client.sendAudio(self.chunk(1))

        // Act: stopping without a transport discards what could never be sent
        // and refuses to hold anything for the dead session.
        client.stop()
        client.sendAudio(self.chunk(2))

        // Assert
        XCTAssertTrue(client.preroll.isEmpty)
    }
}
