import Foundation

/// Float32 → little-endian Int16 linear PCM conversion, shared by the streaming
/// clients that accept `sendAudioSamples`.
///
/// Kept in one place so every provider's sample path funnels into the same
/// `sendAudio` entry point — and therefore the same pre-roll buffering for
/// audio captured before the transport is ready (issue #641).
public enum PCM16Converter {
    public static func data(from samples: UnsafePointer<Float>, frameCount: Int) -> Data {
        guard frameCount > 0 else { return Data() }
        var int16Samples = [Int16](repeating: 0, count: frameCount)
        for index in 0..<frameCount {
            let clampedSample = max(-1.0, min(1.0, samples[index]))
            int16Samples[index] = Int16(clampedSample * Float(Int16.max)).littleEndian
        }
        return int16Samples.withUnsafeBytes { Data($0) }
    }
}
