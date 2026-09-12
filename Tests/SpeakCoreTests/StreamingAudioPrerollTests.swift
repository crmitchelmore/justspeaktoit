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
    /// | Soniox (SpeakApp) | shared `StreamingAudioPreroll` | `Tests/SpeakAppTests/SonioxLivePrerollTests.swift` |
    /// | Gladia | bespoke `pendingAudio`, private, 5s inline cap | not asserted — no visible seam |
    /// | AssemblyAI | bespoke `preBeginAudio`, private, byte cap | not asserted — no visible seam |
    /// | Cartesia | provider-local framed two-second cap | `CartesiaLiveClientTests` |
    /// | Gemini | bespoke `pendingAudio`, private, trimmed | not asserted — no visible seam |
    /// | xAI | bespoke `pendingAudio`, private, trimmed | not asserted — no visible seam |
    /// | **Modulate** | **none — `sendAudio` returns early with no socket** | **gap, tracked by #947** |
    ///
    /// Modulate is the only shared live client that drops pre-socket audio
    /// outright. That is a production defect, not a test gap, and it is fixed
    /// under issue #947; when it adopts the shared buffer, add its row below.
    ///
    /// `SonioxLiveTranscriber` in `SpeakApp` owns the same shared buffer, so it
    /// is in the table above, but it is a macOS-only provider that this target
    /// cannot construct — hence the separate file rather than a row in
    /// `sharedPrerollClients`.
    ///
    /// Each row carries the capture rate that client streams at, because the
    /// budget is seconds of audio and therefore a *different* byte ceiling per
    /// client. Asserting against the largest supported rate would let a 16kHz
    /// client hold fifteen seconds and still pass.
    private func sharedPrerollClients() -> [PrerollClientRow] {
        [
            PrerollClientRow(
                name: "Deepgram",
                sampleRate: 16_000,
                client: DeepgramLiveClient(apiKey: "k", model: "nova-3")
            ),
            PrerollClientRow(
                name: "ElevenLabs", sampleRate: 16_000, client: ElevenLabsLiveClient(apiKey: "k")
            ),
            PrerollClientRow(
                name: "Soniox", sampleRate: 16_000, client: SonioxLiveClient(apiKey: "k")
            ),
            PrerollClientRow(
                name: "MetaMuse", sampleRate: 24_000, client: MetaMuseLiveClient(apiKey: "k")
            )
        ]
    }

    func testEverySharedPrerollClient_RetainsPreConnectionAudioInCaptureOrder() {
        for row in self.sharedPrerollClients() {
            let (name, client) = (row.name, row.client)
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
        for row in self.sharedPrerollClients() {
            let (name, client) = (row.name, row.client)
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

    func testEverySharedPrerollClient_BoundsWhatItHoldsToItsOwnSampleRateBudget() {
        for row in self.sharedPrerollClients() {
            let (name, sampleRate, client) = (row.name, row.sampleRate, row.client)
            // Arrange: a transport that never comes up. Without a bound this is
            // an unbounded allocation for the whole recording.
            XCTAssertEqual(
                client.preroll.snapshot.byteCount, 0, "\(name) should start with an empty buffer"
            )

            // The budget is five seconds of audio, which is a different byte
            // ceiling at each capture rate. Pin the rate the client configured
            // as well as the bound it enforces, so a client that silently
            // switched rate — and so silently changed how much it can hold —
            // fails here rather than passing under a looser ceiling.
            let expectedBudgetBytes = Int(
                Double(sampleRate * 2) * StreamingAudioPreroll.defaultBudgetSeconds
            )
            XCTAssertEqual(
                client.preroll.maximumByteCount,
                expectedBudgetBytes,
                "\(name) is not budgeting five seconds of \(sampleRate)Hz PCM16"
            )

            // Act: an hour of 24kHz PCM16 would be ~170MB; 400 chunks is enough
            // to prove the bound without the runtime cost.
            for index in 0..<400 {
                client.sendAudio(self.chunk(UInt8(index % 251), count: 3_200))
            }

            // Assert
            let snapshot = client.preroll.snapshot
            XCTAssertGreaterThan(
                snapshot.droppedChunkCount,
                0,
                "\(name) never evicted anything — its pre-roll is unbounded"
            )
            XCTAssertLessThanOrEqual(
                snapshot.byteCount,
                expectedBudgetBytes,
                "\(name) held more than five seconds of its own \(sampleRate)Hz audio"
            )
        }
    }
}

/// The shared-buffer contract, declared here rather than in production so the
/// test can iterate over clients that have no common protocol of their own.
private struct PrerollClientRow {
    let name: String
    /// The capture rate this client streams at, and therefore the rate its
    /// seconds-based pre-roll budget resolves against.
    let sampleRate: Int
    let client: PrerollHoldingClient
}

private protocol PrerollHoldingClient: AnyObject {
    var preroll: StreamingAudioPreroll { get }
    func sendAudio(_ audioData: Data)
    func stop()
}

extension DeepgramLiveClient: PrerollHoldingClient {}
extension ElevenLabsLiveClient: PrerollHoldingClient {}
extension SonioxLiveClient: PrerollHoldingClient {}
extension MetaMuseLiveClient: PrerollHoldingClient {}
