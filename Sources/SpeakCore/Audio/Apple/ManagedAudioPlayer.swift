import AVFoundation
import Foundation
import os

/// Owns the current `AVAudioPlayer` and its delegate.
///
/// AVFoundation calls the delegate on a thread of its choosing and does not
/// retain it, so each owner used to repeat the same care: detach the delegate
/// before stopping or dropping a player, hop the callback to the main actor,
/// and ignore a callback from a player that has since been replaced. This type
/// does all three.
///
/// **Contract.** `onEnd` runs on the main actor at most once per play of the
/// current player. A play starts with `adopt(_:)` and again with every
/// `play()`, which is also how a finished player is replayed or a paused one
/// resumed; start playback through `play()`, not `AVAudioPlayer.play()`, or
/// its end is not reported. A second callback for the same play (a decode
/// error followed by a finish, or a duplicate finish) is dropped, and so is a
/// callback queued for an earlier play, a replaced player or a stopped one.
@MainActor
public final class ManagedAudioPlayer {
    public enum Ending: Equatable, Sendable {
        case finished(successfully: Bool)
        case decodeFailed
    }

    /// The player that is playing, paused or ready, or nil after `stop()`.
    public private(set) var player: AVAudioPlayer?
    private let forwarder: Forwarder
    private let onEnd: (AVAudioPlayer, Ending) -> Void
    private let startPlayback: (AVAudioPlayer) -> Bool
    /// The current play, readable from AVFoundation's callback thread.
    private let playCounter = PlayCounter()
    /// The last play whose end reached `onEnd`.
    private var reportedPlay: Int?

    /// `startPlayback` starts the player for `play()`; tests replace it so no
    /// native output opens.
    public init(
        startPlayback: @escaping (AVAudioPlayer) -> Bool = { $0.play() },
        onEnd: @escaping (AVAudioPlayer, Ending) -> Void
    ) {
        self.onEnd = onEnd
        self.startPlayback = startPlayback
        let owner = WeakOwner()
        let playCounter = playCounter
        forwarder = Forwarder { reference, ending in
            // Read on the callback thread, so a replay that starts before this
            // hop runs cannot claim the earlier play's end.
            let play = playCounter.current
            Task { @MainActor in owner.value?.deliver(ending, from: reference.player, play: play) }
        }
        owner.value = self
    }

    deinit {
        player?.delegate = nil
        player?.stop()
    }

    /// Makes `player` current. Any previous player is detached and stopped
    /// first, so its late callbacks can never reach `onEnd`.
    public func adopt(_ player: AVAudioPlayer) {
        stop()
        player.delegate = forwarder
        self.player = player
        playCounter.advance()
    }

    /// Starts, resumes or replays the current player as a new play, whose end
    /// `onEnd` reports once. Returns false when there is no player or it did
    /// not start.
    @discardableResult
    public func play() -> Bool {
        guard let player else { return false }
        playCounter.advance()
        return startPlayback(player)
    }

    /// Detaches and stops the current player and forgets it.
    public func stop() {
        guard let player else { return }
        player.delegate = nil
        player.stop()
        self.player = nil
    }

    private func deliver(_ ending: Ending, from player: AVAudioPlayer, play: Int) {
        guard self.player === player, play == playCounter.current, reportedPlay != play else { return }
        reportedPlay = play
        onEnd(player, ending)
    }
}

/// Numbers each play. Advanced on the main actor, read on AVFoundation's
/// callback thread.
private final class PlayCounter: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)

    var current: Int { value.withLock { $0 } }

    func advance() {
        value.withLock { $0 &+= 1 }
    }
}

/// Lets the forwarder find its owner without retaining it. Only read and
/// written on the main actor.
@MainActor
private final class WeakOwner {
    weak var value: ManagedAudioPlayer?
}

/// Keeps a player alive until its callback reaches the main actor, so the
/// identity check cannot match a new player at a reused address. Only
/// dereferenced on the main actor.
private struct PlayerReference: @unchecked Sendable {
    let player: AVAudioPlayer
}

private final class Forwarder: NSObject, AVAudioPlayerDelegate, Sendable {
    private let deliver: @Sendable (PlayerReference, ManagedAudioPlayer.Ending) -> Void

    init(deliver: @escaping @Sendable (PlayerReference, ManagedAudioPlayer.Ending) -> Void) {
        self.deliver = deliver
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        deliver(PlayerReference(player: player), .finished(successfully: flag))
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        deliver(PlayerReference(player: player), .decodeFailed)
    }
}
