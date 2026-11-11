import AVFoundation
import Foundation
import os

/// The running recorder's input meter, readable from the 30 Hz UI timer
/// without a hop onto the recorder actor. `AVAudioRecorder` metering is
/// documented as thread-safe; the lock only guards which recorder is current.
struct RecorderMeter: Sendable {
  private let current = OSAllocatedUnfairLock<AVAudioRecorder?>(uncheckedState: nil)

  /// Meters `recorder` from now on, or nothing when nil.
  func attach(_ recorder: AVAudioRecorder?) {
    current.withLockUnchecked { $0 = recorder }
  }

  /// One meter update: the normalized level (0.0 to 1.0) and the peak input
  /// power in dBFS since the previous update (digital silence reads -160 dB).
  /// Nil when no recorder is running.
  func reading() -> (level: Float, peakDecibels: Float)? {
    guard let recorder = current.withLockUnchecked({ $0 }), recorder.isRecording else { return nil }
    recorder.updateMeters()

    let averagePower = recorder.averagePower(forChannel: 0)
    let peakPower = recorder.peakPower(forChannel: 0)

    // Combine average and peak for responsive meter
    let combinedPower = (averagePower * 0.7) + (peakPower * 0.3)

    // Convert decibels to normalized linear scale (0.0 to 1.0)
    // -60 dB = silence threshold, 0 dB = maximum
    let minDb: Float = -60
    let level = max(0, min(1, (combinedPower - minDb) / (-minDb)))
    return (level, peakPower)
  }
}
