import AVFoundation
import Foundation

/// Owns the current `AVAudioPlayer` and its delegate.
///
/// AVFoundation calls the delegate on a thread of its choosing and does not
/// retain it, so each owner used to repeat the same care: detach the delegate
/// before stopping or dropping a player, hop the callback to the main actor,
/// and ignore a callback from a player that has since been replaced. This type
/// does all three; `onEnd` runs on the main actor, once per natural end of the
/// player that is still current.
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

    public init(onEnd: @escaping (AVAudioPlayer, Ending) -> Void) {
        self.onEnd = onEnd
        let owner = WeakOwner()
        forwarder = Forwarder { reference, ending in
            Task { @MainActor in owner.value?.deliver(ending, from: reference.player) }
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
    }

    /// Detaches and stops the current player and forgets it.
    public func stop() {
        guard let player else { return }
        player.delegate = nil
        player.stop()
        self.player = nil
    }

    private func deliver(_ ending: Ending, from player: AVAudioPlayer) {
        guard self.player === player else { return }
        onEnd(player, ending)
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
