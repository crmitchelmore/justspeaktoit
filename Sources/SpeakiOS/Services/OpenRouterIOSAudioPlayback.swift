#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

/// One playback operation. Delegate callbacks never target a replacement operation.
@MainActor
final class OpenRouterIOSAudioPlayback: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var hasStarted = false
    private var observers: [NSObjectProtocol] = []
    private var completionDeadline: ContinuousClock.Instant?
    private var sessionLease: OpenRouterIOSAudioSessionLease?
    private var completion: Result<Void, OpenRouterIOSVoiceOutputError>?

    var isFinished: Bool { completion != nil }

    func start(at url: URL, speed: Double) throws {
        guard !hasStarted else { throw OpenRouterIOSVoiceOutputError.playbackFailed }
        hasStarted = true
        let audioPlayer: AVAudioPlayer
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
        } catch {
            throw OpenRouterIOSVoiceOutputError.playbackFailed
        }
        audioPlayer.enableRate = true
        audioPlayer.rate = Self.playbackRate(for: speed)
        guard audioPlayer.duration.isFinite, audioPlayer.duration > 0 else {
            throw OpenRouterIOSVoiceOutputError.playbackFailed
        }
        completionDeadline = ContinuousClock().now.advanced(
            by: .seconds(audioPlayer.duration / Double(audioPlayer.rate) + 5)
        )
        audioPlayer.delegate = self
        player = audioPlayer
        guard audioPlayer.prepareToPlay() else { throw OpenRouterIOSVoiceOutputError.playbackFailed }
        sessionLease = try OpenRouterIOSAudioSessionLease.acquire()
        observeInterruptions()
        try AVAudioSession.sharedInstance().setActive(true)
        guard audioPlayer.play() else { throw OpenRouterIOSVoiceOutputError.playbackFailed }
    }

    func checkCompletion() throws {
        guard let completion else { throw OpenRouterIOSVoiceOutputError.playbackFailed }
        try completion.get()
    }

    func checkProgress() throws {
        if completion == nil, let completionDeadline, ContinuousClock().now >= completionDeadline {
            throw OpenRouterIOSVoiceOutputError.playbackFailed
        }
    }

    func stop() {
        player?.delegate = nil
        player?.stop()
        player = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        completionDeadline = nil
        sessionLease?.restoreIfUnchanged()
        sessionLease = nil
    }

    static func playbackRate(for speed: Double) -> Float {
        let finiteSpeed = speed.isFinite ? speed : 1
        let range = VoiceOutputProvider.openrouter.speedRange
        return Float(min(max(finiteSpeed, range.lowerBound), range.upperBound))
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identifier = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let activePlayer = self.player,
                  ObjectIdentifier(activePlayer) == identifier, self.completion == nil else { return }
            self.completion = flag ? .success(()) : .failure(.playbackFailed)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let identifier = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let activePlayer = self.player,
                  ObjectIdentifier(activePlayer) == identifier, self.completion == nil else { return }
            self.completion = .failure(.playbackFailed)
        }
    }

    private func observeInterruptions() {
        let names = [
            AVAudioSession.interruptionNotification,
            AVAudioSession.routeChangeNotification,
            AVAudioSession.mediaServicesWereLostNotification,
            AVAudioSession.mediaServicesWereResetNotification
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
                guard Self.interruptsPlayback(notice) else { return }
                MainActor.assumeIsolated {
                    guard let self, self.player != nil else { return }
                    // The system or a recorder now owns the session; cleanup must not reconfigure it.
                    self.sessionLease = nil
                    self.player?.stop()
                    self.completion = .failure(.interrupted)
                }
            }
        }
    }

    nonisolated static func interruptsPlayback(_ notice: Notification) -> Bool {
        OpenRouterIOSAudioSessionLease.interruptsPlayback(notice)
    }
}

#endif
