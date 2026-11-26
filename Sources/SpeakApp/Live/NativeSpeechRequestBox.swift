import AVFoundation
import Foundation
@preconcurrency import Speech

/// Receives PCM audio buffers during a speech recognition session.
protocol NativeSpeechBufferSink: AnyObject {
    func append(_ audioPCMBuffer: AVAudioPCMBuffer)
}

extension SFSpeechAudioBufferRecognitionRequest: NativeSpeechBufferSink {}

/// Thread-safe mutable reference to the active recognition request so audio
/// callbacks (microphone taps and `SystemAudioLiveFeed`) always forward PCM
/// buffers to the current request across mid-session restarts without holding
/// the lock while appending.
final class NativeSpeechRequestBox<Sink: NativeSpeechBufferSink>: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Sink?

    /// Gets or replaces the active recognition request sink.
    var request: Sink? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    /// Atomically returns and clears the active sink on session stop.
    func take() -> Sink? {
        lock.withLock {
            let pending = current
            current = nil
            return pending
        }
    }

    /// Forwards a PCM buffer to whichever sink is currently active.
    func append(_ buffer: AVAudioPCMBuffer) {
        let active = lock.withLock { current }
        active?.append(buffer)
    }
}
