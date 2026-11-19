#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

/// Why a voice-output playback ended before the audio did. Each client maps it
/// onto its own error surface.
enum VoiceOutputPlaybackError: LocalizedError, Equatable {
    case playbackFailed
    case interrupted
    case recordingInProgress

    var errorDescription: String? {
        switch self {
        case .playbackFailed: "The voice audio could not be played."
        case .interrupted: "Voice playback was interrupted. Try again when audio is available."
        case .recordingInProgress: "Stop the current recording before playing voice output."
        }
    }
}

/// One `AVAudioPlayer` and its delegate, for the player's whole life.
///
/// `AVAudioPlayer.delegate` is unretained, so the delegate is cleared before
/// the player is stopped or released: a late callback can never reach freed
/// memory, and the owner checks this handle's identity before believing one.
final class VoiceOutputAudioPlayerHandle: NSObject, AVAudioPlayerDelegate {
    let player: AVAudioPlayer
    private let onFinish: (ObjectIdentifier, Bool) -> Void

    init(player: AVAudioPlayer, onFinish: @escaping (ObjectIdentifier, Bool) -> Void) {
        self.player = player
        self.onFinish = onFinish
        super.init()
        player.delegate = self
    }

    func stop() {
        player.delegate = nil
        player.stop()
    }

    deinit {
        player.delegate = nil
        player.stop()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish(ObjectIdentifier(self), flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish(ObjectIdentifier(self), false)
    }
}

/// One voice-output playback, from audio-session lease to completion.
///
/// The player's own completion callback ends the wait; nothing polls. A player
/// that never reports back fails five seconds after its audio should have
/// ended. The lease is restored as soon as playback ends, and the session is
/// never deactivated here: a recorder may own it by then.
@MainActor
final class VoiceOutputAudioPlayback {
    enum Source {
        case file(URL)
        case data(Data)
    }

    /// System boundaries, replaceable so ownership tests never start an audio device.
    @MainActor
    struct Dependencies {
        var makePlayer: (Source) throws -> AVAudioPlayer = { source in
            switch source {
            case .file(let url): try AVAudioPlayer(contentsOf: url)
            case .data(let data): try AVAudioPlayer(data: data)
            }
        }
        var acquireLease: () throws -> VoiceOutputAudioSessionLease? = { try .acquire() }
        var activate: () throws -> Void = { try AVAudioSession.sharedInstance().setActive(true) }
        var notifications: NotificationCenter = .default
        var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    }

    private let dependencies: Dependencies
    private var handle: VoiceOutputAudioPlayerHandle?
    private var hasStarted = false
    private var observers: [NSObjectProtocol] = []
    private var sessionLease: VoiceOutputAudioSessionLease?
    private var deadline: Task<Void, Never>?
    private var completion: Result<Void, VoiceOutputPlaybackError>?
    private var waiter: CheckedContinuation<Void, Error>?

    convenience init() {
        self.init(dependencies: Dependencies())
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var isFinished: Bool { completion != nil }

    /// Starts playback. On failure everything this call acquired is released.
    func start(_ source: Source, rate: Float) throws {
        guard !hasStarted else { throw VoiceOutputPlaybackError.playbackFailed }
        hasStarted = true
        do {
            try begin(source, rate: rate)
        } catch {
            release()
            throw error
        }
    }

    /// Waits for the started playback to end. ``stop()`` and task cancellation
    /// both end the wait with `CancellationError`.
    func waitForCompletion() async throws {
        if completion == nil {
            try Task.checkCancellation()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { waiter = $0 }
            } onCancel: {
                Task { @MainActor [weak self] in self?.stop() }
            }
        }
        guard let completion else { throw CancellationError() }
        try completion.get()
    }

    func stop() {
        release()
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }

    static func playbackRate(
        for speed: Double, in range: ClosedRange<Double> = VoiceOutputProvider.openrouter.speedRange
    ) -> Float {
        let finiteSpeed = speed.isFinite ? speed : 1
        return Float(min(max(finiteSpeed, range.lowerBound), range.upperBound))
    }

    nonisolated static func interruptsPlayback(_ notice: Notification) -> Bool {
        VoiceOutputAudioSessionLease.interruptsPlayback(notice)
    }

    private func begin(_ source: Source, rate: Float) throws {
        let player: AVAudioPlayer
        do {
            player = try dependencies.makePlayer(source)
        } catch {
            throw VoiceOutputPlaybackError.playbackFailed
        }
        player.enableRate = true
        player.rate = rate
        guard player.duration.isFinite, player.duration > 0 else { throw VoiceOutputPlaybackError.playbackFailed }
        let handle = VoiceOutputAudioPlayerHandle(player: player) { [weak self] identifier, succeeded in
            Task { @MainActor [weak self] in
                self?.finish(succeeded ? .success(()) : .failure(.playbackFailed), from: identifier)
            }
        }
        self.handle = handle
        guard player.prepareToPlay() else { throw VoiceOutputPlaybackError.playbackFailed }
        sessionLease = try dependencies.acquireLease()
        observeInterruptions()
        try dependencies.activate()
        guard player.play() else { throw VoiceOutputPlaybackError.playbackFailed }
        scheduleDeadline(after: player.duration / Double(max(player.rate, 0.01)) + 5, for: ObjectIdentifier(handle))
    }

    private func scheduleDeadline(after seconds: TimeInterval, for identifier: ObjectIdentifier) {
        let sleep = dependencies.sleep
        deadline = Task { [weak self] in
            guard (try? await sleep(.seconds(seconds))) != nil else { return }
            self?.finish(.failure(.playbackFailed), from: identifier)
        }
    }

    /// Accepts the first outcome for the current player only.
    private func finish(_ outcome: Result<Void, VoiceOutputPlaybackError>, from identifier: ObjectIdentifier) {
        guard let handle, ObjectIdentifier(handle) == identifier, completion == nil else { return }
        completion = outcome
        release()
        waiter?.resume()
        waiter = nil
    }

    private func release() {
        handle?.stop()
        handle = nil
        deadline?.cancel()
        deadline = nil
        observers.forEach { dependencies.notifications.removeObserver($0) }
        observers.removeAll()
        sessionLease?.restoreIfUnchanged()
        sessionLease = nil
    }

    private func observeInterruptions() {
        let names = [
            AVAudioSession.interruptionNotification,
            AVAudioSession.routeChangeNotification,
            AVAudioSession.mediaServicesWereLostNotification,
            AVAudioSession.mediaServicesWereResetNotification
        ]
        observers = names.map { name in
            dependencies.notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
                guard Self.interruptsPlayback(notice) else { return }
                MainActor.assumeIsolated {
                    guard let self, let handle = self.handle else { return }
                    // The system or a recorder now owns the session; cleanup must not reconfigure it.
                    self.sessionLease = nil
                    self.finish(.failure(.interrupted), from: ObjectIdentifier(handle))
                }
            }
        }
    }
}

#endif
