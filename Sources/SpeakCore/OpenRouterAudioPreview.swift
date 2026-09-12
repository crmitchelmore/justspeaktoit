import AVFoundation
import Combine
import Foundation

/// Owns transient test content and audio. It does not write history, preferences, or logs.
@MainActor
final class OpenRouterAudioPreview: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isBusy = false
    @Published private(set) var isPlaying = false
    @Published private(set) var transcript = ""
    @Published private(set) var status = ""
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var audioURL: URL?
    private var player: AVAudioPlayer?
    #if os(iOS)
    private var interruptionObserver: NSObjectProtocol?
    private var audioSessionLease: OpenRouterPreviewAudioSessionLease?
    #endif

    override init() {
        super.init()
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: rawType) == .began else { return }
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                self.audioSessionLease = nil
                self.finishPlayback(player: player, message: "Audio preview was interrupted. Try again.")
            }
        }
        #endif
    }

    deinit {
        operation?.cancel()
        // onDisappear normally calls cancel; deletion also survives owner teardown.
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        #if os(iOS)
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        audioSessionLease?.restore()
        #endif
    }

    func transcribe(file: URL, model: String, client: OpenRouterAudioClient) {
        cancel()
        let identifier = generation
        isBusy = true
        operation = Task { [weak self] in
            let scoped = file.startAccessingSecurityScopedResource()
            defer { if scoped { file.stopAccessingSecurityScopedResource() } }
            let started = Date()
            do {
                let result = try await client.transcribe(audioFileURL: file, model: model)
                try Task.checkCancellation()
                guard let self, self.generation == identifier else { return }
                self.transcript = result.text
                self.status = "Transcription completed in \(Self.elapsed(since: started)) seconds."
                self.isBusy = false
                self.operation = nil
            } catch {
                self?.finish(error: error, identifier: identifier)
            }
        }
    }

    func speak(text: String, model: String, voice: String?, client: OpenRouterAudioClient) {
        cancel()
        let identifier = generation
        isBusy = true
        operation = Task { [weak self] in
            let started = Date()
            do {
                let result = try await client.synthesize(text: text, model: model, voice: voice)
                guard !Task.isCancelled, let self, self.generation == identifier else {
                    try? FileManager.default.removeItem(at: result.audioURL)
                    return
                }
                self.audioURL = result.audioURL
                let player = try AVAudioPlayer(contentsOf: result.audioURL)
                player.delegate = self
                self.player = player
                #if os(iOS)
                self.audioSessionLease = try OpenRouterPreviewAudioSessionLease.acquire()
                #endif
                guard player.play() else { throw URLError(.cannotDecodeContentData) }
                self.isPlaying = true
                self.isBusy = false
                self.operation = nil
                self.status = "Speech ready in \(Self.elapsed(since: started)) seconds."
            } catch {
                self?.finish(error: error, identifier: identifier)
            }
        }
    }

    func cancel() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        releaseAudio()
        isBusy = false
        transcript = ""
        status = ""
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let reference = OpenRouterPreviewPlayerReference(player: player)
        Task { @MainActor [weak self] in
            self?.finishPlayback(player: reference.player, message: flag ? nil : "Audio playback failed. Try again.")
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let reference = OpenRouterPreviewPlayerReference(player: player)
        Task { @MainActor [weak self] in
            self?.finishPlayback(
                player: reference.player, message: "Audio playback failed. Try another model or sample."
            )
        }
    }

    private func finishPlayback(player: AVAudioPlayer, message: String?) {
        guard self.player === player else { return }
        releaseAudio()
        if let message { status = message }
    }

    private func finish(error: Error, identifier: UUID) {
        guard generation == identifier else { return }
        releaseAudio()
        isBusy = false
        operation = nil
        // Client errors contain safe, fixed messages; never display provider response bodies.
        status = (error as? LocalizedError)?.errorDescription ?? "The audio test failed. Check your key and connection."
    }

    private func releaseAudio() {
        player?.stop()
        player = nil
        isPlaying = false
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
        #if os(iOS)
        audioSessionLease?.restore()
        audioSessionLease = nil
        #endif
    }

    private static func elapsed(since start: Date) -> String {
        String(format: "%.1f", Date().timeIntervalSince(start))
    }
}

/// Keeps an old player alive until its delegate callback reaches the main actor,
/// preventing identity reuse. The reference is only dereferenced on MainActor;
/// AVAudioPlayer is never accessed concurrently through this transfer wrapper.
private struct OpenRouterPreviewPlayerReference: @unchecked Sendable {
    let player: AVAudioPlayer
}

#if os(iOS)
/// Borrows playback configuration without deactivating a session owned by capture.
/// AVAudioSession does not expose whether it was already active, so this lease
/// restores only configuration it changed and never unconditionally deactivates.
private struct OpenRouterPreviewAudioSessionLease {
    let category: AVAudioSession.Category
    let mode: AVAudioSession.Mode
    let options: AVAudioSession.CategoryOptions

    static func acquire() throws -> Self? {
        let session = AVAudioSession.sharedInstance()
        // Playback is already supported by these categories; leave the recorder's
        // routing, mixing, mode and activation entirely under its owner's control.
        if session.category == .playAndRecord || session.category == .multiRoute { return nil }
        guard session.category != .record else { throw OpenRouterPreviewPlaybackError.recordingSession }
        let lease = Self(category: session.category, mode: session.mode, options: session.categoryOptions)
        // AVAudioPlayer activates the session when playback starts. Mixing keeps
        // this short preview from taking ownership of another app's audio.
        try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
        return lease
    }

    func restore() {
        let session = AVAudioSession.sharedInstance()
        // A recording or another player may have taken over after the preview
        // started. Never overwrite the newer owner's configuration.
        guard session.category == .playback, session.mode == .spokenAudio,
              session.categoryOptions == [.mixWithOthers] else { return }
        try? session.setCategory(category, mode: mode, options: options)
    }
}

private enum OpenRouterPreviewPlaybackError: LocalizedError {
    case recordingSession

    var errorDescription: String? {
        "Finish the active recording before playing an audio preview."
    }
}
#endif
