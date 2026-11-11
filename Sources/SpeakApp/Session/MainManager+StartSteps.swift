import SpeakCore
import AVFoundation
import AppKit
import Foundation

/// The steps `RecordingStartSequencer` runs for a session, and the latency
/// checkpoints they record.
extension MainManager {
  /// Shows the HUD as "Getting ready" when this session shows one. Returns
  /// whether it does.
  func showRecordingHUDIfNeeded(for trigger: SessionTriggerSource) -> Bool {
    // A hands-free capture always moves the HUD to the recording pane, even
    // when the user hides the HUD for their own sessions: the armed pane
    // otherwise claims the app only listens while it in fact records.
    // Showing that the microphone captures is a privacy duty, not a taste.
    let showsHUD = appSettings.showHUDDuringSessions || trigger == .handsFree
    guard showsHUD else { return false }
    // Up straight away as "Getting ready"; its clock starts only when the
    // microphone delivers real audio, never while words can't be heard.
    // Uses the cached microphone status: each TCC query costs 13-35 ms
    // before capture (#611), and `startRecording` makes the authoritative
    // check moments later; the HUD health is refreshed once capture is live.
    hudManager.updateCaptureHealth(captureHealth.snapshot())
    hudManager.beginRecording(profileName: profileApplier.activeProfileName, awaitingAudio: true)
    return true
  }

  /// The sequencer step that opens the live stream, nil for batch modes.
  func makeStartStreamStep(
    for session: ActiveSession,
    trigger: SessionTriggerSource,
    preRollBuffers: [AVAudioPCMBuffer],
    primedInput: PrimedLiveInputReservation?
  ) -> RecordingStartSequencer.Step? {
    guard isStreamingTranscriptionMode else { return nil }
    return { [weak self, transcriptionManager, preRollBuffers, trigger, primedInput] in
      let primedCapture = await primedInput?.value
      try await transcriptionManager.startLiveTranscription(
        preRollBuffers: preRollBuffers,
        analyzerFallbackAllowed: trigger != .handsFree,
        primedInput: primedCapture,
        onDiagnostic: { [weak self] receipt in
          Self.retainBatchDiagnostic(receipt, for: session, activeSession: self?.activeSession)
        }
      )
      guard self?.activeSession === session else { return }
      session.liveTranscriptSessionID = transcriptionManager.liveTranscript.sessionID
    }
  }

  /// The sequencer step that starts the recorder and publishes the recording.
  func makeStartCaptureStep(
    for session: ActiveSession,
    warmContext: CaptureWarmContext?,
    showsHUD: Bool
  ) -> RecordingStartSequencer.Step {
    { [weak self] in
      guard let self else { return }
      let recording = try await self.audioFileManager.startRecording(
        warmContext: warmContext,
        owner: .dictation
      )
      // The stop could have landed while `startRecording()` was suspended.
      // Publish nothing for a session that is already over — throw away the
      // capture that just came up instead.
      guard self.activeSession === session else {
        await self.discardStartedCapture()
        throw RecordingStartAbort.sessionEnded
      }
      self.recordCaptureStart(for: session, wasWarm: recording.usedWarmRecorder)
      self.state = .recording
      session.events.append(
        HistoryEvent(
          kind: .recordingStarted,
          description: "Recording started via \(session.gesture.rawValue)"
        )
      )
      if showsHUD {
        self.hudManager.updateCaptureHealth(self.captureHealth.snapshot())
      }
      self.beginAwaitingAudio(for: session)
      self.startAudioLevelMonitoring()
    }
  }

  /// Plays the "recording started" cue, unless the user already stopped (or a
  /// newer session replaced this one) while capture was coming up — a late cue
  /// after the stop cue would be worse than no cue at all.
  func playRecordingStartCue(for session: ActiveSession) {
    guard self.activeSession === session, self.state == .recording else {
      self.logger.info("Skipping start cue: session ended before capture was ready")
      return
    }
    guard appSettings.recordingSoundsEnabled else { return }
    recordingSoundPlayer.play(.start, volume: appSettings.recordingSoundVolume)
  }

  /// Latency checkpoint: the recorder is live. hotkey → capture-start is the
  /// cold-start figure competitors market, so log it explicitly every session,
  /// tagged with whether the pre-warmed recorder was used (issue #663) so the
  /// dashboard percentiles can be read against the warm/cold split.
  ///
  /// Called from the start sequencer's capture step, so the checkpoint is taken
  /// the moment capture is *proven* live rather than when it was requested.
  func recordCaptureStart(for session: ActiveSession, wasWarm: Bool) {
    session.captureStarted = Date()
    session.captureStartedUptime = ProcessInfo.processInfo.systemUptime
    if let coldStartMs = session.captureStartMilliseconds {
      let path = wasWarm ? "pre-warmed" : "cold"
      self.logger.info("Latency: capture started \(coldStartMs)ms after trigger (\(path, privacy: .public))")
    }
    if let keyDownMs = session.keyDownToCaptureMilliseconds {
      self.logger.info("Latency: capture started \(keyDownMs)ms after key-down")
    }
  }

  /// Throws away capture that came up for a session nobody is listening to any
  /// more (the user stopped, or a replacement session started, while the start
  /// was suspended). Without this the recorder keeps running and the file is
  /// never claimed by any session.
  func discardStartedCapture() async {
    stopAudioLevelMonitoring()
    await audioFileManager.cancelRecording(deleteFile: true)
  }

  /// Records the full start timeline (capture, streaming tap, cue) in history
  /// so a clipped-start report can be diagnosed from the session alone
  /// (issue #641).
  func recordStartTimeline(for session: ActiveSession, timeline: RecordingStartTimeline) {
    let summary = timeline.diagnosticSummary
    guard !summary.isEmpty else { return }
    self.logger.info("Recording start timeline: \(summary, privacy: .public)")
    session.events.append(
      HistoryEvent(
        kind: .recordingStarted,
        description: "Start timeline — \(summary)"
      )
    )
  }
}
