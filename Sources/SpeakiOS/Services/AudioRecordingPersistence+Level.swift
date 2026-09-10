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
// The metered value is read from the main actor at
// `CaptureEndPointingPolicy.sampleIntervalSeconds` and written on whichever
// thread delivered the buffer, so it is published through a leaf lock in
// `AudioRecordingPersistence` as an `InputLevelSample` — level plus a buffer
// sequence — rather than left as an unsynchronised `Float`. The sequence is
// what lets the sampler tell a fresh observation from the same one read twice,
// so a level that has stopped being refreshed cannot be counted as new silence
// in the middle of an utterance.

/// One metered observation of the microphone: the level of a buffer, and a
/// counter that identifies *which* buffer it came from.
///
/// The sequence exists so a reader can tell a fresh observation from the same
/// one read twice. End-pointing samples ten times a second while buffers
/// arrive far more often, but if audio stops flowing entirely the last level
/// would otherwise keep being counted as new evidence — and a stale silent
/// reading is exactly what can end an utterance that is still in progress.
public struct CaptureInputLevelSample: Sendable, Equatable {
    public let levelDBFS: Float
    /// Increments once per metered buffer, from 0 at the start of a capture.
    /// Two reads with the same sequence are one observation, not two.
    public let sequence: UInt64

    public init(levelDBFS: Float, sequence: UInt64) {
        self.levelDBFS = levelDBFS
        self.sequence = sequence
    }
}

/// Lock-guarded holder for the metered level.
///
/// Written from whichever thread delivered the buffer and read from the main
/// actor, so it takes a leaf lock rather than being left as an unsynchronised
/// `nonisolated(unsafe) Float`: level and sequence have to be one coherent
/// observation, and an unsynchronised `Float` is a data race, not a cheap
/// approximation of one. The lock is taken for a single struct assignment or
/// a single read and is never held across anything else, so it cannot
/// participate in an ordering with the persistence state lock or its I/O queue.
final class CaptureInputLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var sample = CaptureInputLevelSample(
        levelDBFS: AudioLevelMeter.silenceFloorDBFS,
        sequence: 0
    )

    var current: CaptureInputLevelSample { lock.withLock { sample } }

    func publish(_ levelDBFS: Float) {
        lock.withLock {
            sample = CaptureInputLevelSample(levelDBFS: levelDBFS, sequence: sample.sequence &+ 1)
        }
    }

    func reset() {
        lock.withLock {
            sample = CaptureInputLevelSample(levelDBFS: AudioLevelMeter.silenceFloorDBFS, sequence: 0)
        }
    }
}

extension AudioRecordingPersistence {
    /// The most recent metered observation, read as one value.
    nonisolated public var inputLevelSample: CaptureInputLevelSample { inputLevelMeter.current }

    /// Input level of the most recent buffer, in dBFS.
    nonisolated public var currentInputLevelDBFS: Float { inputLevelSample.levelDBFS }

    /// Forgets the metered level, so the first sample of a new capture cannot
    /// be the last sample of the previous one. Without this a capture starting
    /// in a silent room could inherit a loud reading, count it as speech, and
    /// become eligible to end-point one window later having heard nothing.
    nonisolated public func resetInputLevel() { inputLevelMeter.reset() }

    nonisolated func publishInputLevel(_ levelDBFS: Float) { inputLevelMeter.publish(levelDBFS) }

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
