import AVFoundation
import Foundation
import os.log

/// Plays short UI feedback sounds for recording start/stop.
///
/// Uses `AVAudioPlayer` under the hood and expects the audio files to be bundled resources.
@MainActor
public final class RecordingSoundPlayer {
  public enum RecordingSound: Sendable {
    case start
    case stop

    var resourceName: String {
      switch self {
      case .start: return "recording_start"
      case .stop: return "recording_stop"
      }
    }

    var fileExtension: String { "m4a" }
  }

  private let logger = Logger(subsystem: "com.github.speakapp", category: "RecordingSoundPlayer")

  private var players: [RecordingSound: AVAudioPlayer] = [:]

  public init() {}

  /// Preloads the sound(s) so playback is instant.
  public func preload() {
    _ = player(for: .start)
    _ = player(for: .stop)
  }

  public func play(_ sound: RecordingSound, volume: Float = 1.0) {
    guard let p = player(for: sound) else {
      logger.debug("Recording sound missing: \(sound.resourceName).\(sound.fileExtension)")
      return
    }

    // Restart from the beginning for reliable feedback.
    p.currentTime = 0
    p.volume = max(0, min(1, volume))
    p.prepareToPlay()
    p.play()
  }

  private func player(for sound: RecordingSound) -> AVAudioPlayer? {
    if let existing = players[sound] {
      return existing
    }

    guard let url = Bundle.main.url(forResource: sound.resourceName, withExtension: sound.fileExtension) else {
      return nil
    }

    do {
      let player = try AVAudioPlayer(contentsOf: url)
      player.numberOfLoops = 0
      players[sound] = player
      return player
    } catch {
      logger.warning("Failed to init AVAudioPlayer for \(sound.resourceName).\(sound.fileExtension): \(error.localizedDescription)")
      return nil
    }
  }
}
