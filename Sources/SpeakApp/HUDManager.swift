import Combine
import Foundation

// @Implement: This file is the state manager for the Heads-Up display. It exposes lifecycle functions so that another class can notify it when recording has started, transcribing has started, post-processing has started, etc. It has an enum for all the states it can be in and is a state machine. It also has the ability to surface errors in any of those things and it has an internal timer that shows the duration of each step.

@MainActor
final class HUDManager: ObservableObject {
  struct Snapshot: Equatable {
    enum Phase: Equatable {
      case hidden
      case recording
      case transcribing
      case postProcessing
      case delivering
      case success(message: String)
      case failure(message: String)

      var isTerminal: Bool {
        switch self {
        case .success, .failure:
          return true
        default:
          return false
        }
      }

      var isVisible: Bool {
        self != .hidden
      }
    }

    var phase: Phase
    var headline: String
    var subheadline: String?
    var elapsed: TimeInterval

    static let hidden = Snapshot(phase: .hidden, headline: "", subheadline: nil, elapsed: 0)
  }

  @Published private(set) var snapshot: Snapshot = .hidden

  private var timer: Timer?
  private var phaseStartDate: Date?

  func beginRecording() {
    transition(.recording, headline: "Recording", subheadline: "Capturing audio")
  }

  func beginTranscribing() {
    transition(.transcribing, headline: "Transcribing", subheadline: "Preparing raw transcript")
  }

  func beginPostProcessing() {
    transition(.postProcessing, headline: "Post-processing", subheadline: "Cleaning up transcript")
  }

  func beginDelivering() {
    transition(.delivering, headline: "Delivering", subheadline: "Pasting into target app")
  }

  func finishSuccess(message: String) {
    transition(
      .success(message: message), headline: "Completed", subheadline: message, showsTimer: false)
    scheduleAutoHide()
  }

  func finishFailure(message: String) {
    transition(
      .failure(message: message), headline: "Something went wrong", subheadline: message,
      showsTimer: false)
    scheduleAutoHide()
  }

  func hide() {
    invalidateTimer()
    snapshot = .hidden
  }

  private func transition(
    _ phase: Snapshot.Phase,
    headline: String,
    subheadline: String?,
    showsTimer: Bool = true
  ) {
    invalidateTimer()
    phaseStartDate = showsTimer ? Date() : nil
    snapshot = Snapshot(phase: phase, headline: headline, subheadline: subheadline, elapsed: 0)

    guard showsTimer else { return }

    timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, let start = self.phaseStartDate else { return }
        let elapsed = Date().timeIntervalSince(start)
        self.snapshot.elapsed = elapsed
      }
    }
    if let timer {
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  private func scheduleAutoHide() {
    Timer.scheduledTimer(withTimeInterval: 2.4, repeats: false) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.hide()
      }
    }
  }

  private func invalidateTimer() {
    timer?.invalidate()
    timer = nil
  }
}
// @Implement: This file is the state manager for the Heads-Up display. It exposes lifecycle functions so that another class can notify it when recording has started, transcribing has started, post-processing has started, etc. It has an enum for all the states it can be in and is a state machine. It also has the ability to surface errors in any of those things and it has an internal timer that shows the duration of each step.
