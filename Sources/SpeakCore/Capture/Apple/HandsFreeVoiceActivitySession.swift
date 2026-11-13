@preconcurrency import AVFoundation
import Foundation

/// Feeds microphone buffers to ``HandsFreeEnergyVoiceActivityDetector`` and
/// reports voice activity for hands-free arming.
///
/// Only signal levels are computed: no Speech framework module runs while the
/// session is armed, so nothing is recognised and no transcript exists until
/// speech starts a separate capture. This replaces the SpeechDetector-only
/// `SpeechAnalyzer`, which macOS 27 refuses to run (#1553).
public final class HandsFreeVoiceActivitySession: @unchecked Sendable {
    private let lock = NSLock()
    private var detector: HandsFreeEnergyVoiceActivityDetector
    private var isCancelled = false
    private let onActivity: @Sendable (AppleSpeechActivityUpdate) -> Void

    /// - Parameter onActivity: called for every analysed buffer, on the thread
    ///   that called ``send(_:)``. Callers debounce with
    ///   `HandsFreeVoiceActivityTracker`.
    public init(
        sensitivity: AppleSpeechDetectorSensitivity = HandsFreeDictationPolicy.sensitivity,
        onActivity: @escaping @Sendable (AppleSpeechActivityUpdate) -> Void
    ) {
        self.detector = HandsFreeEnergyVoiceActivityDetector(sensitivity: sensitivity)
        self.onActivity = onActivity
    }

    /// Analyses one microphone buffer in any PCM format the input node gives.
    /// Safe to call from the audio tap.
    public func send(_ buffer: AVAudioPCMBuffer) {
        guard let samples = Self.monoSamples(from: buffer) else { return }
        let sampleRate = buffer.format.sampleRate
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        let update = detector.process(samples: samples, sampleRate: sampleRate)
        lock.unlock()
        if let update { onActivity(update) }
    }

    /// Starts a new utterance, keeping the learned noise floor.
    public func resetSpeech() {
        lock.lock()
        detector.resetSpeech()
        lock.unlock()
    }

    public func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    /// Down-mixes a buffer to mono Float samples in -1...1, or `nil` for a
    /// format or rate that can't be analysed.
    static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let format = buffer.format
        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        guard AppleLocalModels.isUsableAudioFormat(sampleRate: format.sampleRate, channelCount: format.channelCount),
              frames > 0 else { return nil }

        let interleaved = format.isInterleaved && channels > 1
        func mix(_ sample: (_ channel: Int, _ frame: Int) -> Float) -> [Float] {
            var mono = [Float](repeating: 0, count: frames)
            let scale = 1 / Float(channels)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += sample(channel, frame) }
                mono[frame] = sum * scale
            }
            return mono
        }

        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let data = buffer.floatChannelData else { return nil }
            return mix { channel, frame in
                interleaved ? data[0][frame * channels + channel] : data[channel][frame]
            }
        case .pcmFormatInt16:
            guard let data = buffer.int16ChannelData else { return nil }
            return mix { channel, frame in
                Float(interleaved ? data[0][frame * channels + channel] : data[channel][frame]) / 32_768
            }
        case .pcmFormatInt32:
            guard let data = buffer.int32ChannelData else { return nil }
            return mix { channel, frame in
                Float(interleaved ? data[0][frame * channels + channel] : data[channel][frame]) / 2_147_483_648
            }
        default:
            return nil
        }
    }
}
