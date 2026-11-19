import SpeakCore
import Combine
import Foundation

/// Carries live transcript and live polish updates to the previews, the HUD
/// and the live text inserter while a session records.
@MainActor
final class LiveTranscriptRelay {
  /// What the relay reads from, and publishes to, the session owner.
  struct Session {
    let isRecording: () -> Bool
    let activeSession: () -> ActiveSession?
    let liveInsertionEnabled: () -> Bool
    let publishPreview: (String) -> Void
    let publishPolishedPreview: (String) -> Void
    let publishIsPolishing: (Bool) -> Void
  }

  private let transcription: TranscriptionManager
  private let polish: LivePolishManager
  private let inserter: LiveTextInserter
  private let hud: HUDManager
  private let settings: AppSettings
  private let session: Session
  private let logger = SpeakLogger.logger(category: "MainManager")
  private var cancellables: Set<AnyCancellable> = []

  init(
    transcription: TranscriptionManager,
    polish: LivePolishManager,
    inserter: LiveTextInserter,
    hud: HUDManager,
    settings: AppSettings,
    session: Session
  ) {
    self.transcription = transcription
    self.polish = polish
    self.inserter = inserter
    self.hud = hud
    self.settings = settings
    self.session = session
  }

  func start() {
    transcription.$liveTranscript
      .receive(on: RunLoop.main)
      .sink { [weak self] snapshot in
        self?.handleLiveTranscriptSnapshot(snapshot)
      }
      .store(in: &cancellables)

    // Subscribe to live polish updates
    polish.$polishedTail
      .receive(on: RunLoop.main)
      .sink { [weak self] polished in
        self?.session.publishPolishedPreview(polished)
      }
      .store(in: &cancellables)

    polish.$isPolishing
      .receive(on: RunLoop.main)
      .sink { [weak self] isPolishing in
        self?.session.publishIsPolishing(isPolishing)
      }
      .store(in: &cancellables)

    // Connect live polish completion to live text inserter
    polish.onPolishComplete = { [weak self] polished in
      guard let self, self.session.liveInsertionEnabled(), self.inserter.isActive else { return }
      self.inserter.update(with: polished)
    }

    // Trigger immediate polish on utterance boundary (AssemblyAI sub-turn signal)
    transcription.$utteranceBoundaryText
      .compactMap { $0 }
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        guard let self, self.settings.speedMode.usesLivePolish, self.session.isRecording() else {
          return
        }
        Task { @MainActor [weak self] in
          guard let self else { return }
          await self.polish.polishNow(
            stableContext: "",
            tailText: self.transcription.livePartialText
          )
        }
      }
      .store(in: &cancellables)
  }

  /// Applies a live-transcript snapshot to the preview and the HUD.
  ///
  /// Delivery is deferred onto the run loop, so a snapshot published by one
  /// recording can arrive after the next one has already started. Snapshots
  /// that no longer belong to the current live session are dropped instead of
  /// repainting the previous recording's text over the live view (issue #643).
  private func handleLiveTranscriptSnapshot(_ snapshot: LiveTranscriptSnapshot) {
    guard snapshot.sessionID == transcription.liveTranscript.sessionID else { return }
    handleLiveTextUpdate(snapshot.text)
    hud.updateLiveTranscription(
      text: snapshot.text,
      isFinal: snapshot.isFinal,
      confidence: snapshot.confidence
    )
  }

  /// Handle live text updates and trigger live polish if enabled
  private func handleLiveTextUpdate(_ text: String) {
    session.publishPreview(text)

    // Latency checkpoint: first non-empty partial while still recording.
    if session.isRecording(), !text.isEmpty,
       let active = session.activeSession(), active.firstPartialReceived == nil {
      active.firstPartialReceived = Date()
      if let firstPartialMs = SessionLatencyMetrics.milliseconds(
        from: active.captureStarted, to: active.firstPartialReceived
      ) {
        logger.info("Latency: first partial \(firstPartialMs)ms after capture start")
      }
    }

    // Live insertion during recording (live-polish full-value mode or the
    // experimental ranged streaming mode; `update` no-ops when inactive).
    if session.isRecording() && inserter.isActive {
      inserter.update(with: text)
    }

    // Trigger live polish if speed mode uses it
    guard settings.speedMode.usesLivePolish else { return }
    guard session.isRecording() else { return }

    polish.textDidChange(
      stableContext: "",  // Simplified - no transcript state model yet
      tailText: text
    )
  }
}
