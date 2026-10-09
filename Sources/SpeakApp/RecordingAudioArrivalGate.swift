import Foundation

/// Holds the HUD clock and the start cue until the microphone is really
/// delivering audio.
///
/// A recorder can be "started" while its input still produces nothing: a
/// Bluetooth headset switching into call mode emits exact digital zeros for
/// ~0.5–0.7 s. Starting the clock (or inviting speech with the cue) at that
/// point counts time in which no word could be heard. Any real microphone's
/// noise floor meters far above digital silence (-160 dB), so the first peak
/// above `signalFloorDecibels` marks arrival. `fallbackDelay` bounds the wait
/// for an input that meters silent (a gated microphone in a quiet room).
struct RecordingAudioArrivalGate {
  struct Actions: OptionSet, Equatable {
    let rawValue: Int
    static let startClock = Actions(rawValue: 1 << 0)
    static let playCue = Actions(rawValue: 1 << 1)
  }

  static let signalFloorDecibels: Float = -150
  static let fallbackDelay: TimeInterval = 1.5

  enum Arrival: Equatable {
    case signal
    case fallback
  }

  private let captureStarted: Date
  private(set) var arrival: Arrival?
  private var cueRequested = false

  init(captureStarted: Date) {
    self.captureStarted = captureStarted
  }

  /// Feeds one meter reading. `peakDecibels` is nil when the input cannot be
  /// metered, which counts as arrival so the start never waits on it.
  mutating func observe(peakDecibels: Float?, at now: Date) -> Actions {
    guard arrival == nil else { return [] }
    if let peakDecibels, peakDecibels <= Self.signalFloorDecibels {
      guard now.timeIntervalSince(captureStarted) >= Self.fallbackDelay else { return [] }
      arrival = .fallback
    } else {
      arrival = .signal
    }
    return cueRequested ? [.startClock, .playCue] : [.startClock]
  }

  /// The start sequence reached its cue step (capture and any stream tap are
  /// running). The cue plays now if audio already arrived, otherwise on arrival.
  mutating func requestCue() -> Actions {
    guard !cueRequested else { return [] }
    cueRequested = true
    return arrival == nil ? [] : [.playCue]
  }
}
