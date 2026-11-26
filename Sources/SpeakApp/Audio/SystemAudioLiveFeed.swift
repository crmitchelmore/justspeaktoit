import AVFoundation
import Foundation
import SpeakCore

/// Live transcription controllers that can consume PCM buffers from a
/// `SystemAudioLiveFeed` instead of opening their own microphone engine.
protocol ExternalAudioFeedAccepting: AnyObject {
    func setExternalAudioFeed(_ feed: SystemAudioLiveFeed?)
}

/// Thread-safe bridge carrying PCM buffers from `SystemAudioCaptureController`
/// into an active live transcription controller (`SharedClientLiveController`,
/// `NativeOSXLiveTranscriber`, or `OpenAIRealtimeLiveController`).
///
/// Backed by `LiveAudioRelay` so buffers produced while the live streaming
/// WebSocket or recogniser is still opening are queued in order and flushed
/// once the consumer attaches.
final class SystemAudioLiveFeed: @unchecked Sendable {
    let source: AudioCaptureSource
    private let relay = LiveAudioRelay<AVAudioPCMBuffer>()

    init(source: AudioCaptureSource) {
        self.source = source
    }

    func send(_ buffer: AVAudioPCMBuffer) {
        relay.send(buffer)
    }

    func attach(_ sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        relay.attach(sink)
    }

    func close() {
        relay.close()
    }
}
