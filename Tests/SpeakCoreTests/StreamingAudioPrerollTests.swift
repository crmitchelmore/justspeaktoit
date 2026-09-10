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

    // MARK: - Every shared-preroll client, one row each (issue #998)

    /// Pre-socket audio loss is a live defect class here (issues #641, #947,
    /// #949), so the contract is asserted once and applied to every client that
    /// adopts the shared buffer, rather than left to whoever remembers to copy
    /// a test. Adopting `StreamingAudioPreroll` in a new client should be one
    /// new row in `sharedPrerollClients`.
    ///
    /// ### Coverage matrix for the shared live clients
    ///
    /// | Client | Pre-socket audio | Covered by |
    /// | --- | --- | --- |
    /// | Deepgram | shared `StreamingAudioPreroll` | this table |
    /// | ElevenLabs | shared `StreamingAudioPreroll` | this table |
    /// | Soniox | shared `StreamingAudioPreroll` | this table |
    /// | Meta Muse | shared `StreamingAudioPreroll` | this table |
    ///
    /// `SonioxLiveTranscriber` in `SpeakApp` owns the same buffer but is a
    /// macOS provider rather than a shared live client, so it is covered by
    /// `Tests/SpeakAppTests/SonioxLivePrerollTests.swift` and stays out of this
    /// table.
    /// | Gladia | bespoke `pendingAudio`, private, 5s inline cap | not asserted — no visible seam |
    /// | AssemblyAI | bespoke `preBeginAudio`, private, byte cap | not asserted — no visible seam |
    /// | Cartesia | bespoke `pendingAudio`, private, byte cap | not asserted — no visible seam |
    /// | Gemini | bespoke `pendingAudio`, private, trimmed | not asserted — no visible seam |
    /// | xAI | bespoke `pendingAudio`, private, trimmed | not asserted — no visible seam |
    /// | **Modulate** | **none — `sendAudio` returns early with no socket** | **gap, tracked by #947** |
    ///
    /// Modulate is the only shared live client that drops pre-socket audio
    /// outright. That is a production defect, not a test gap, and it is fixed
    /// under issue #947; when it adopts the shared buffer, add its row below.
    private func sharedPrerollClients() -> [(name: String, client: PrerollHoldingClient)] {
        [
            ("Deepgram", DeepgramLiveClient(apiKey: "k", model: "nova-3")),
            ("ElevenLabs", ElevenLabsLiveClient(apiKey: "k")),
            ("Soniox", SonioxLiveClient(apiKey: "k")),
            ("MetaMuse", MetaMuseLiveClient(apiKey: "k"))
        ]
    }

    func testEverySharedPrerollClient_RetainsPreConnectionAudioInCaptureOrder() {
        for (name, client) in self.sharedPrerollClients() {
            // Arrange: no `start()`, so there is no running WebSocket — exactly
            // the window between the user's first word and the handshake.
            // Act
            client.sendAudio(self.chunk(1))
            client.sendAudio(self.chunk(2))
            client.sendAudio(self.chunk(3))

            // Assert
            XCTAssertEqual(
                client.preroll.drain(),
                [self.chunk(1), self.chunk(2), self.chunk(3)],
                "\(name) lost or reordered audio captured before its transport was ready"
            )
        }
    }

    func testEverySharedPrerollClient_StopsBufferingOnceTheSessionIsStopping() {
        for (name, client) in self.sharedPrerollClients() {
            // Arrange
            client.sendAudio(self.chunk(1))

            // Act: a stop with no live socket still latches the stopping state,
            // so late tap callbacks must not grow a buffer nothing will drain.
            client.stop()
            client.sendAudio(self.chunk(2))

            // Assert
            XCTAssertTrue(
                client.preroll.isEmpty,
                "\(name) kept holding audio for a session that had already stopped"
            )
        }
    }

    func testEverySharedPrerollClient_BoundsWhatItHoldsToTheSharedBudget() {
        for (name, client) in self.sharedPrerollClients() {
            // Arrange: a transport that never comes up. Without a bound this is
            // an unbounded allocation for the whole recording.
            let budgetBytes = client.preroll.snapshot.byteCount
            XCTAssertEqual(budgetBytes, 0, "\(name) should start with an empty buffer")

            // Act: an hour of 24kHz PCM16 would be ~170MB; 400 chunks is enough
            // to prove the bound without the runtime cost.
            for index in 0..<400 {
                client.sendAudio(self.chunk(UInt8(index % 251), count: 3_200))
            }

            // Assert: the bound is seconds of audio, so express the ceiling the
            // same way rather than hard-coding a byte count per sample rate.
            let snapshot = client.preroll.snapshot
            XCTAssertGreaterThan(
                snapshot.droppedChunkCount,
                0,
                "\(name) never evicted anything — its pre-roll is unbounded"
            )
            XCTAssertLessThanOrEqual(
                snapshot.byteCount,
                Int(48_000 * 2 * StreamingAudioPreroll.defaultBudgetSeconds),
                "\(name) held more than the shared budget allows at any supported sample rate"
            )
        }
    }
}

/// The shared-buffer contract, declared here rather than in production so the
/// test can iterate over clients that have no common protocol of their own.
private protocol PrerollHoldingClient: AnyObject {
    var preroll: StreamingAudioPreroll { get }
    func sendAudio(_ audioData: Data)
    func stop()
}

extension DeepgramLiveClient: PrerollHoldingClient {}
extension ElevenLabsLiveClient: PrerollHoldingClient {}
extension SonioxLiveClient: PrerollHoldingClient {}
extension MetaMuseLiveClient: PrerollHoldingClient {}
