#if os(iOS)
import AVFoundation
import XCTest
@testable import SpeakiOSLib

/// The shared voice-output player: completion comes from the player's own
/// callback, the lease is restored (never deactivated), and the unretained
/// delegate can never reach a stopped or replaced playback.
@MainActor
final class VoiceOutputAudioPlaybackTests: XCTestCase {
    func testCompletionCallback_endsTheWaitAndRestoresTheLease() async throws {
        let fixture = PlaybackFixture()
        let playback = fixture.makePlayback()
        try playback.start(.data(fixture.audio), rate: 1)
        XCTAssertEqual(fixture.session.current.category, .playback)
        let wait = Task { try await playback.waitForCompletion() }
        let player = try XCTUnwrap(fixture.players.last)
        player.delegate?.audioPlayerDidFinishPlaying?(player, successfully: true)
        try await wait.value

        XCTAssertTrue(playback.isFinished)
        XCTAssertEqual(fixture.session.current.category, .ambient, "The lease restores the prior category")
        XCTAssertEqual(fixture.activations, 1)
        XCTAssertNil(player.delegate, "The delegate is cleared once playback ends")
    }

    func testStop_clearsTheDelegateFirstAndALateCallbackIsIgnored() async throws {
        let fixture = PlaybackFixture()
        let playback = fixture.makePlayback()
        try playback.start(.data(fixture.audio), rate: 1)
        let player = try XCTUnwrap(fixture.players.last)
        let lateDelegate = try XCTUnwrap(player.delegate)
        let wait = Task { try await playback.waitForCompletion() }
        await Task.yield()
        playback.stop()

        do {
            try await wait.value
            XCTFail("Stopping ends the wait")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(player.delegate)
        XCTAssertEqual(player.delegateClearedBeforeStop, true)
        lateDelegate.audioPlayerDidFinishPlaying?(player, successfully: true)
        await Task.yield()
        XCTAssertFalse(playback.isFinished, "A retired player's callback is never believed")
    }

    func testInterruption_failsWithoutReconfiguringTheSession() async throws {
        let fixture = PlaybackFixture()
        let playback = fixture.makePlayback()
        try playback.start(.data(fixture.audio), rate: 1)
        let wait = Task { try await playback.waitForCompletion() }
        fixture.notifications.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
        ])
        do {
            try await wait.value
            XCTFail("An interruption ends playback")
        } catch {
            XCTAssertEqual(error as? VoiceOutputPlaybackError, .interrupted)
        }
        XCTAssertEqual(fixture.session.writes.count, 1, "The new session owner keeps its configuration")
    }

    func testMissingCallback_failsAfterTheDeadline() async throws {
        let fixture = PlaybackFixture()
        fixture.sleep = { _ in }
        let playback = fixture.makePlayback()
        try playback.start(.data(fixture.audio), rate: 1)
        do {
            try await playback.waitForCompletion()
            XCTFail("A silent player cannot wait forever")
        } catch {
            XCTAssertEqual(error as? VoiceOutputPlaybackError, .playbackFailed)
        }
        XCTAssertEqual(fixture.session.current.category, .ambient)
    }

    func testRecordingSession_refusesBeforePlaying() throws {
        let fixture = PlaybackFixture(category: .record)
        let playback = fixture.makePlayback()
        XCTAssertThrowsError(try playback.start(.data(fixture.audio), rate: 1)) {
            XCTAssertEqual($0 as? VoiceOutputPlaybackError, .recordingInProgress)
        }
        XCTAssertEqual(fixture.players.last?.plays, 0)
        XCTAssertNil(fixture.players.last?.delegate)
    }

    func testDeepgram_stopEndsPlaybackQuietlyAndCancellationStopsTheAudio() async throws {
        let fixture = PlaybackFixture()
        let client = DeepgramTTSClient(session: .shared, makePlayback: fixture.makePlayback)
        let stopped = Task { try await client.play(fixture.audio) }
        await settle { client.isSpeaking }
        client.stop()
        try await stopped.value
        XCTAssertFalse(client.isSpeaking)
        XCTAssertNil(client.error)
        XCTAssertEqual(fixture.session.current.category, .ambient)

        let cancelled = Task { try await client.play(fixture.audio) }
        await settle { client.isSpeaking }
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("Cancelling the caller cancels playback")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThan(try XCTUnwrap(fixture.players.last).stops, 0, "Cancelled audio does not keep playing")
        XCTAssertFalse(client.isSpeaking)
        XCTAssertNil(client.error)
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<100 where !done() { await Task.yield() }
    }
}

@MainActor
private final class PlaybackFixture {
    let session: LeaseConfigurationFixture
    let notifications = NotificationCenter()
    var players: [FakeVoicePlayer] = []
    var activations = 0
    var sleep: (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(60)) }
    let audio = PlaybackFixture.silentWAV()

    init(category: AVAudioSession.Category = .ambient) {
        session = LeaseConfigurationFixture(category: category)
    }

    func makePlayback() -> VoiceOutputAudioPlayback {
        var dependencies = VoiceOutputAudioPlayback.Dependencies()
        dependencies.makePlayer = { [unowned self] source in
            guard case .data(let data) = source else { throw VoiceOutputPlaybackError.playbackFailed }
            let player = try FakeVoicePlayer(data: data)
            players.append(player)
            return player
        }
        let access = session.access
        dependencies.acquireLease = { try VoiceOutputAudioSessionLease.acquire(using: access) }
        dependencies.activate = { [unowned self] in activations += 1 }
        dependencies.notifications = notifications
        dependencies.sleep = { [unowned self] in try await sleep($0) }
        return VoiceOutputAudioPlayback(dependencies: dependencies)
    }

    /// A tenth of a second of 8 kHz mono 16-bit silence.
    static func silentWAV() -> Data {
        let samples = 800, bytes = samples * 2
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + bytes))
        data.append(contentsOf: Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(8_000)); append(UInt32(16_000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Data("data".utf8))
        append(UInt32(bytes))
        data.append(Data(count: bytes))
        return data
    }
}

/// Records play/stop without producing sound.
private final class FakeVoicePlayer: AVAudioPlayer {
    var plays = 0
    var stops = 0
    var delegateClearedBeforeStop: Bool?

    override func prepareToPlay() -> Bool { true }
    override func play() -> Bool {
        plays += 1
        return true
    }
    override func stop() {
        if delegateClearedBeforeStop == nil { delegateClearedBeforeStop = delegate == nil }
        stops += 1
    }
}
#endif
