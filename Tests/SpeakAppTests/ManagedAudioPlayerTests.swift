import AVFoundation
import SpeakCore
import XCTest

@MainActor
final class ManagedAudioPlayerTests: XCTestCase {
    private var directory: URL!
    private var endings: [(AVAudioPlayer, ManagedAudioPlayer.Ending)] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManagedAudioPlayerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A player over a short silent WAV. Tests never call `play()`, so no
    /// native output opens; they drive the delegate directly.
    private func makePlayer() throws -> AVAudioPlayer {
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        try file.write(from: buffer)
        return try AVAudioPlayer(contentsOf: url)
    }

    private func makeOwner() -> ManagedAudioPlayer {
        // `play()` re-arms without starting native output.
        ManagedAudioPlayer(
            startPlayback: { _ in true },
            onEnd: { [unowned self] player, ending in self.endings.append((player, ending)) }
        )
    }

    /// Lets the forwarder's main-actor hop run.
    private func drainMainActor() async {
        for _ in 0..<5 { await Task.yield() }
    }

    func testAdopt_forwardsTheCurrentPlayersEndOnTheMainActor() async throws {
        let owner = makeOwner()
        let player = try makePlayer()
        owner.adopt(player)

        player.delegate?.audioPlayerDidFinishPlaying?(player, successfully: true)
        await drainMainActor()

        XCTAssertEqual(endings.map(\.1), [.finished(successfully: true)])
        XCTAssertTrue(endings.allSatisfy { $0.0 === player })
    }

    func testEnd_isReportedOncePerPlay() async throws {
        let owner = makeOwner()
        let player = try makePlayer()
        owner.adopt(player)
        let delegate = try XCTUnwrap(player.delegate)

        delegate.audioPlayerDecodeErrorDidOccur?(player, error: nil)
        delegate.audioPlayerDidFinishPlaying?(player, successfully: false)
        delegate.audioPlayerDidFinishPlaying?(player, successfully: false)
        await drainMainActor()

        XCTAssertEqual(endings.map(\.1), [.decodeFailed], "Decode then finish, and a duplicate finish, end one play")
    }

    func testPlay_replayingTheSamePlayerReportsItsEndAgain() async throws {
        let owner = makeOwner()
        let player = try makePlayer()
        owner.adopt(player)
        let delegate = try XCTUnwrap(player.delegate)
        delegate.audioPlayerDidFinishPlaying?(player, successfully: true)
        await drainMainActor()

        XCTAssertTrue(owner.play())
        delegate.audioPlayerDidFinishPlaying?(player, successfully: true)
        await drainMainActor()

        XCTAssertEqual(endings.count, 2, "Each play of the same History player completes")
        XCTAssertTrue(endings.allSatisfy { $0.0 === player })
    }

    func testPlay_dropsAnEndQueuedForThePreviousPlay() async throws {
        let owner = makeOwner()
        let player = try makePlayer()
        owner.adopt(player)
        let delegate = try XCTUnwrap(player.delegate)

        // The first play ends, and the user replays before the hop runs.
        delegate.audioPlayerDidFinishPlaying?(player, successfully: true)
        owner.play()
        await drainMainActor()
        XCTAssertTrue(endings.isEmpty, "The earlier play's end must not stand in for the replay's")

        delegate.audioPlayerDidFinishPlaying?(player, successfully: true)
        await drainMainActor()
        XCTAssertEqual(endings.count, 1)
    }

    func testPlay_withoutAPlayerDoesNothing() {
        XCTAssertFalse(makeOwner().play())
    }

    func testAdopt_detachesTheReplacedPlayerAndDropsItsQueuedCallback() async throws {
        let owner = makeOwner()
        let old = try makePlayer()
        owner.adopt(old)
        let oldDelegate = try XCTUnwrap(old.delegate)

        owner.adopt(try makePlayer())
        // A callback AVFoundation dispatched just before the replacement.
        oldDelegate.audioPlayerDidFinishPlaying?(old, successfully: true)
        await drainMainActor()

        XCTAssertNil(old.delegate)
        XCTAssertTrue(endings.isEmpty)
    }

    func testStop_detachesBeforeForgettingAndIgnoresLateCallbacks() async throws {
        let owner = makeOwner()
        let player = try makePlayer()
        owner.adopt(player)
        let delegate = try XCTUnwrap(player.delegate)

        owner.stop()
        delegate.audioPlayerDidFinishPlaying?(player, successfully: false)
        await drainMainActor()

        XCTAssertNil(player.delegate)
        XCTAssertNil(owner.player)
        XCTAssertTrue(endings.isEmpty)
    }

    func testDeinit_detachesTheDelegate() throws {
        let player = try makePlayer()
        var owner: ManagedAudioPlayer? = makeOwner()
        owner?.adopt(player)
        XCTAssertNotNil(player.delegate)

        owner = nil

        XCTAssertNil(player.delegate)
    }
}
