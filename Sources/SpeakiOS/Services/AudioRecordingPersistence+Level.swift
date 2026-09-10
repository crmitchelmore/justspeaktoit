#if os(iOS)
import AVFoundation
import Foundation
import SpeakCore

// Input-level metering for silence end-pointing (issue #1012).
//
// `AudioRecordingPersistence` is the one place every iOS capture buffer already
// passes through: all four transcribers — Apple, OpenAI Realtime, the shared
// streaming client and the batch recorder — call `writeBuffer` from their own
// tap. Metering here rather than in each of those four taps is what lets
// end-pointing work on all of them, batch mode included. Batch publishes no
// partial results at all, so an end-pointing rule written against the
// transcript could never fire for anyone using it.
//
// `currentInputLevelDBFS` is read from the main actor at
// `CaptureEndPointingPolicy.sampleIntervalSeconds` and written on whichever
// thread delivered the buffer. A torn `Float` read is not worth a lock on every
// buffer: it is one sample of a level re-read ten times a second, and the
// silence window is many samples long.

extension AudioRecordingPersistence {
    /// Forgets the metered level, so the first sample of a new capture cannot
    /// be the last sample of the previous one. Without this a capture starting
    /// in a silent room could inherit a loud reading, count it as speech, and
    /// become eligible to end-point one window later having heard nothing.
    nonisolated public func resetInputLevel() {
        currentInputLevelDBFS = AudioLevelMeter.silenceFloorDBFS
    }

    /// RMS level of one buffer, in dBFS.
    ///
    /// Only the first channel is measured: the input node is mono in every
    /// capture path here, and averaging channels would let one dead channel
    /// halve the level. An unrecognised sample format reports silence, which is
    /// the safe direction — it can only make a capture run longer, never cut
    /// one short, because `CaptureEndPointingMonitor` refuses to end-point on
    /// silence it has never heard speech before.
    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return AudioLevelMeter.silenceFloorDBFS }
        if let channel = buffer.floatChannelData?.pointee {
            var sumOfSquares: Double = 0
            for index in 0..<frames {
                let sample = Double(channel[index])
                sumOfSquares += sample * sample
            }
            return AudioLevelMeter.decibels(rms: Float((sumOfSquares / Double(frames)).squareRoot()))
        }
        if let channel = buffer.int16ChannelData?.pointee {
            var sumOfSquares: Double = 0
            for index in 0..<frames {
                let sample = Double(channel[index]) / 32_768
                sumOfSquares += sample * sample
            }
            return AudioLevelMeter.decibels(rms: Float((sumOfSquares / Double(frames)).squareRoot()))
        }
        return AudioLevelMeter.silenceFloorDBFS
    }
}
#endif
