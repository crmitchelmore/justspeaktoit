import SpeakCore
import AVFoundation
import SwiftUI

struct AudioPlaybackControls: View {
  @StateObject private var controller: AudioPlaybackController

  init(url: URL) {
    _controller = StateObject(wrappedValue: AudioPlaybackController(url: url))
  }

  var body: some View {
    HStack(spacing: 16) {
      Button(action: controller.togglePlayPause) {
        Label(
          controller.state == .playing ? "Pause" : "Play",
          systemImage: controller.state == .playing ? "pause.circle.fill" : "play.circle.fill"
        )
        .labelStyle(.titleAndIcon)
      }
      .buttonStyle(.borderedProminent)
      .speakTooltip("Tap to listen back and double-check what Speak heard for this session.")

      Button(action: controller.stop) {
        Label("Stop", systemImage: "stop.circle")
      }
      .buttonStyle(.bordered)
      .disabled(controller.state == .idle)
      .speakTooltip("Stop playback and reset the audio timer back to the beginning.")

      Text(controller.formattedTime)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }
}

@MainActor
final class AudioPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
  enum PlaybackState {
    case idle
    case playing
    case paused
  }

  @Published private(set) var state: PlaybackState = .idle
  @Published private(set) var currentTime: TimeInterval = 0

  private var player: AVAudioPlayer?
  private var timer: Timer?

  init(url: URL) {
    super.init()
    configurePlayer(url: url)
  }

  deinit {
    timer?.invalidate()
    player?.stop()
  }

  func togglePlayPause() {
    guard let player else { return }
    switch state {
    case .playing:
      player.pause()
      state = .paused
      timer?.invalidate()
    case .paused:
      player.play()
      state = .playing
      startTimer()
    case .idle:
      player.currentTime = 0
      player.play()
      state = .playing
      startTimer()
    }
  }

  func stop() {
    guard let player else { return }
    player.stop()
    player.currentTime = 0
    state = .idle
    currentTime = 0
    timer?.invalidate()
  }

  var formattedTime: String {
    guard let duration = player?.duration, duration.isFinite else { return "--:--" }
    let current = currentTime
    let remaining = max(duration - current, 0)
    return "\(format(current)) / \(format(remaining))"
  }

  private func configurePlayer(url: URL) {
    do {
      let player = try AVAudioPlayer(contentsOf: url)
      player.delegate = self
      player.prepareToPlay()
      self.player = player
    } catch {
      player = nil
    }
  }

  private func startTimer() {
    timer?.invalidate()
    // Use target-selector pattern to avoid Swift concurrency crashes during deallocation.
    // Block-based timers with [weak self] can crash in swift_getObjectType during executor
    // verification when the object is deallocating.
    timer = Timer.scheduledTimer(
      timeInterval: 0.05,
      target: self,
      selector: #selector(timerFired),
      userInfo: nil,
      repeats: true
    )
    if let timer {
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  @objc private func timerFired() {
    guard let player else { return }
    currentTime = player.currentTime
    if !player.isPlaying {
      state = .idle
      timer?.invalidate()
    }
  }

  private func format(_ time: TimeInterval) -> String {
    guard time.isFinite else { return "--:--.--" }
    let hundredths = Int((time * 100).rounded())
    let minutes = hundredths / 6000
    let seconds = (hundredths / 100) % 60
    let fractional = hundredths % 100
    return String(format: "%02d:%02d.%02d", minutes, seconds, fractional)
  }

  func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    timer?.invalidate()
    currentTime = 0
    state = .idle
  }
}
