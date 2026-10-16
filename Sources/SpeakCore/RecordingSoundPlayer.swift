import AVFoundation
import Foundation
import os.log

/// Plays short UI feedback sounds for recording start/stop.
///
/// Uses `AVAudioPlayer` under the hood and expects the audio files to be bundled resources.
@MainActor
public final class RecordingSoundPlayer {
  public typealias RecordingSound = RecordingFeedbackSound
  public typealias SoundProfile = RecordingFeedbackProfile

  private let logger = SpeakLogger.logger(category: "RecordingSoundPlayer")

  public var profile: SoundProfile = RecordingFeedbackDefaults.profile {
    didSet {
      if profile != oldValue {
        players.removeAll()
        preload()
      }
    }
  }

  private var players: [RecordingSound: AVAudioPlayer] = [:]

  public init() {}

  /// Preloads the sound(s) so playback is instant.
  public func preload() {
    _ = player(for: .start)
    _ = player(for: .stop)
  }

  public func play(_ sound: RecordingSound, volume: Float = 1.0) {
    guard let p = player(for: sound) else {
      logger.debug("Recording sound missing: \(self.resourceName(for: sound)).\(sound.fileExtension)")
      return
    }

    // Restart from the beginning for reliable feedback.
    p.currentTime = 0
    p.volume = RecordingFeedbackDefaults.gain(for: volume)
    p.prepareToPlay()
    p.play()
  }

  private func player(for sound: RecordingSound) -> AVAudioPlayer? {
    if let existing = players[sound] {
      return existing
    }

    let resource = resourceName(for: sound)
    guard let url = Bundle.main.url(forResource: resource, withExtension: sound.fileExtension) else {
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

  private func resourceName(for sound: RecordingSound) -> String {
    profile.resourceName(for: sound)
  }
}
