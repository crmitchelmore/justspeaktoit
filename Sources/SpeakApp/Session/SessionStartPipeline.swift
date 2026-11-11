import SpeakCore
import AVFoundation
import AppKit
import Foundation
import os.log

/// The session the start pipeline brings up, and the façade state it reads
/// and publishes. `MainManager` is the only host.
@MainActor
protocol SessionStartHost: AnyObject {
  var activeSession: ActiveSession? { get }
  /// False while a migration runs or another session is active.
  var mayStartSession: Bool { get }
  var isStreamingTranscriptionMode: Bool { get }
  /// Makes `session` current and resets the previews, retry offer and live insertion.
  func activate(_ session: ActiveSession)
  /// Capture is proven live for `session`: publish `.recording`.
  func captureDidStart(for session: ActiveSession)
  /// A start rejected before any session existed.
  func publishStartRejection(_ message: String)
  func publishMissingLiveAPIKey(_ alert: MissingLiveAPIKeyAlert)
  /// The admission snapshot for a new session's History entry.
  func makeAdmissionDiagnosticContext() -> HistoryDiagnosticContext
  /// See `MainManager.sessionProcessingShouldContinue(_:)`.
  func sessionProcessingShouldContinue(_ session: ActiveSession) -> Bool
  /// Tears down a session whose capture failed to start.
  func failStartedSession(message: String)
}

/// Admits a dictation start and brings capture up: per-app profile, admission
/// checks, the capture reservation, then `RecordingStartSequencer` (prepare the
/// live input, start the recorder, open the stream, play the cue). Owns the
/// "a start is in progress" fact; everything after `.started` belongs to the
/// stop path.
@MainActor
final class SessionStartPipeline {
  struct Request {
    var trigger: SessionTriggerSource
    var preRollBuffers: [AVAudioPCMBuffer] = []
    var triggerTiming: SessionTriggerTiming = .nonHotKey()
    var primedInput: PrimedLiveInputReservation?
  }

  /// The session-scoped owners the start hands work to.
  struct Owners {
    let captureRuntime: SessionCaptureRuntime
    let captureHealth: CaptureHealthMonitor
    let keyPressPrimer: KeyPressPrimerRuntime
    let captureWarmer: CaptureWarmCoordinator
    let captureOwnership: CaptureSessionOwnership
    let retirement: SessionRetirement
    let profileApplier: SessionProfileApplier
    let soundPlayer: RecordingSoundPlayer
  }

  /// True while a start is between admission and `.started` or rejection.
  private(set) var isStarting = false
  weak var host: SessionStartHost?

  let settings: AppSettings
  private let capture: SessionCaptureServices
  private let transcription: TranscriptionManager
  private let postProcessing: PostProcessingManager
  let hud: HUDManager
  let owners: Owners
  private let logger = SpeakLogger.logger(category: "SessionStartPipeline")

  init(
    settings: AppSettings,
    capture: SessionCaptureServices,
    transcription: TranscriptionManager,
    postProcessing: PostProcessingManager,
    hud: HUDManager,
    owners: Owners
  ) {
    self.settings = settings
    self.capture = capture
    self.transcription = transcription
    self.postProcessing = postProcessing
    self.hud = hud
    self.owners = owners
  }

  func start(_ request: Request) async -> HandsFreeCaptureStartOutcome {
    // Every exit closes a primed microphone this start did not take over.
    defer { owners.keyPressPrimer.release(request.primedInput) }
    guard let host, host.mayStartSession, !isStarting else { return .rejected(.captureFailed) }
    isStarting = true
    defer { isStarting = false }
    owners.keyPressPrimer.sessionWillBegin()
    owners.captureWarmer.sessionWillBegin()

    // Per-app dictation profile: resolve the frontmost app and apply its
    // overrides for this session only. Applied before the API-key check so the
    // check sees the profile's provider. Reverted whenever `activeSession`
    // returns to nil; the rejections below revert explicitly because no
    // session was created yet.
    owners.profileApplier.begin(
      settings: settings,
      postProcessing: postProcessing,
      profiles: capture.profiles.profiles,
      frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    )

    let admission = SessionStartAdmission(
      settings: settings,
      capture: capture,
      transcription: transcription,
      hud: hud,
      ownership: owners.captureOwnership,
      retirement: owners.retirement
    )
    if let rejection = await admission.rejection(for: request.trigger, host: host) {
      return rejection
    }

    // Failsafe: if live transcription is still running but we have no activeSession,
    // cancel it so the app can always recover without requiring a restart.
    //
    // The switcher serialises this teardown with a replacement start and guards
    // ownership by run, including when both runs reuse the same controller.
    if transcription.isLiveTranscribing {
      logger.warning("Live transcription still running without an active session; cancelling to recover")
      transcription.cancelLiveTranscription()
    }

    let session = ActiveSession(
      gesture: request.trigger.historyGesture,
      hotKeyDescription: settings.selectedHotKey.displayString,
      trigger: request.trigger,
      triggerTiming: request.triggerTiming
    )
    session.outputTarget = TextOutputTarget.capture()
    session.diagnosticContext = host.makeAdmissionDiagnosticContext()
    session.isLocalAutomationCapture = true
    host.activate(session)

    return await runStartSequence(for: session, request: request, host: host)
  }

  // MARK: - Start sequence

  /// Brings up capture (and the live stream) for a session that now exists,
  /// then plays the start cue. Abandons quietly if the session ended meanwhile.
  private func runStartSequence(
    for session: ActiveSession,
    request: Request,
    host: SessionStartHost
  ) async -> HandsFreeCaptureStartOutcome {
    // Claim the recorder staged while idle. Returns nil — and the cold path
    // runs — whenever the environment moved since it was staged.
    let warmContext = owners.captureWarmer.claimWarmContext()
    let liveInputPreparation = LiveInputPreparation(
      deviceManager: capture.devices,
      engines: LiveInputEngines.shared,
      primed: request.primedInput
    )

    do {
      // Issue #641: the start cue is played by the sequencer *after* capture is
      // proven live (and, in streaming modes, after the audio tap is running),
      // so the user is never invited to speak into a microphone that isn't
      // listening yet. The pre-warm path (issue #663) runs inside the same
      // step — a claimed staged recorder still has to prove it is capturing.
      let startStream = makeStartStreamStep(for: session, request: request, host: host)
      // The live engine's input node is built before the recorder opens the
      // microphone; built afterwards it stalled stream start (and the cue) by
      // ~3 s on Bluetooth inputs. See `LiveInputEngineStore`. Routes that
      // capture through their own engine (WhisperKit) would never claim it.
      let prepareStream: RecordingStartSequencer.Step? = capture.audioFiles.requiresPhysicalInput
        && transcription.liveRouteUsesLiveInputEngine
        ? { await liveInputPreparation.prepare() }
        : nil
      if let primedInput = request.primedInput, prepareStream == nil {
        // This route builds its own input node (or none); it must not do so
        // beside the primer's open microphone.
        await owners.keyPressPrimer.closeBeforeStart(primedInput)
      }
      let hudDuringStart = beginStartingHUD(for: request, buildsInputNode: prepareStream != nil)
      let sequencer = RecordingStartSequencer(
        isSessionCurrent: { [weak host] in host?.activeSession === session },
        prepareStream: prepareStream,
        discardPreparedStream: { await liveInputPreparation.finish(startFailed: true) },
        startCapture: makeStartCaptureStep(for: session, warmContext: warmContext, hud: hudDuringStart, host: host),
        discardCapture: { [weak self] in await self?.discardStartedCapture() },
        startStream: startStream,
        discardStream: { [transcription] in transcription.cancelLiveTranscription() },
        playCue: { [owners] in owners.captureRuntime.requestStartCue(for: session) }
      )
      let timeline = try await sequencer.run()
      await liveInputPreparation.finish()
      Self.recordStartTimeline(timeline, for: session, logger: logger)
      await recordKeyDownLatency(for: session, primedInput: request.primedInput)
      return .started
    } catch is RecordingStartAbort {
      await liveInputPreparation.finish(startFailed: true)
      hud.cancelAwaitingAudio()
      // Not a failure: the session ended while startup was suspended, and the
      // sequencer has already torn down whatever it brought up. Touching the
      // shared failure path here would clobber the session that replaced it.
      logger.info("Recording start abandoned: the session ended before capture was ready")
      return .rejected(.captureFailed)
    } catch {
      await liveInputPreparation.finish(startFailed: true)
      guard host.sessionProcessingShouldContinue(session) else { return .rejected(.captureFailed) }
      session.errors.append(
        HistoryError(
          phase: .recording,
          message: "Failed to start recording",
          debugDescription: error.localizedDescription
        )
      )
      host.failStartedSession(message: error.localizedDescription)
      return .rejected(HandsFreeDictationMachine.Failure(error))
    }
  }

  /// The sequencer step that opens the live stream, nil for batch modes.
  private func makeStartStreamStep(
    for session: ActiveSession,
    request: Request,
    host: SessionStartHost
  ) -> RecordingStartSequencer.Step? {
    guard host.isStreamingTranscriptionMode else { return nil }
    let preRollBuffers = request.preRollBuffers
    let analyzerFallbackAllowed = request.trigger != .handsFree
    let primedInput = request.primedInput
    return { [weak host, transcription] in
      let primedCapture = await primedInput?.value
      try await transcription.startLiveTranscription(
        preRollBuffers: preRollBuffers,
        analyzerFallbackAllowed: analyzerFallbackAllowed,
        primedInput: primedCapture,
        onDiagnostic: { [weak host] receipt in
          MainManager.retainBatchDiagnostic(receipt, for: session, activeSession: host?.activeSession)
        }
      )
      guard host?.activeSession === session else { return }
      session.liveTranscriptSessionID = transcription.liveTranscript.sessionID
    }
  }

  /// The sequencer step that starts the recorder and publishes the recording.
  private func makeStartCaptureStep(
    for session: ActiveSession,
    warmContext: CaptureWarmContext?,
    hud presentation: HUDDuringStart,
    host: SessionStartHost
  ) -> RecordingStartSequencer.Step {
    { [weak self, weak host] in
      guard let self else { return }
      let audioFiles = self.capture.audioFiles
      // Main-actor reads happen here, before the hop, so the recorder's
      // actor never waits for the main thread on its way to `record()`.
      let preflight = await audioFiles.makeStartPreflight()
      async let startedRecording = audioFiles.startRecording(
        warmContext: warmContext, owner: .dictation, preflight: preflight
      )
      if presentation.presentsWhileOpening {
        self.presentStartingHUD()
      }
      let recording = try await startedRecording
      // The stop could have landed while `startRecording()` was suspended.
      // Publish nothing for a session that is already over — throw away the
      // capture that just came up instead.
      guard let host, host.activeSession === session else {
        await self.discardStartedCapture()
        throw RecordingStartAbort.sessionEnded
      }
      Self.recordCaptureStart(for: session, recording: recording, logger: self.logger)
      host.captureDidStart(for: session)
      session.events.append(
        HistoryEvent(kind: .recordingStarted, description: "Recording started via \(session.gesture.rawValue)")
      )
      if presentation.shows {
        self.hud.updateCaptureHealth(self.owners.captureHealth.snapshot())
      }
      self.owners.captureRuntime.begin(session)
    }
  }

  /// Plays the "recording started" cue, unless the user already stopped (or a
  /// newer session replaced this one) while capture was coming up — a late cue
  /// after the stop cue would be worse than no cue at all.
  func playStartCue(for session: ActiveSession, isRecording: Bool) {
    guard host?.activeSession === session, isRecording else {
      logger.info("Skipping start cue: session ended before capture was ready")
      return
    }
    guard settings.recordingSoundsEnabled else { return }
    owners.soundPlayer.play(.start, volume: settings.recordingSoundVolume)
  }

  /// Throws away capture that came up for a session nobody is listening to any
  /// more (the user stopped, or a replacement session started, while the start
  /// was suspended). Without this the recorder keeps running and the file is
  /// never claimed by any session.
  private func discardStartedCapture() async {
    owners.captureRuntime.stop()
    await capture.audioFiles.cancelRecording(deleteFile: true)
  }

  // MARK: - Latency records

  /// Latency checkpoint: the recorder is live. hotkey → capture-start is the
  /// cold-start figure competitors market, so log it explicitly every session,
  /// tagged with whether the pre-warmed recorder was used (issue #663) so the
  /// dashboard percentiles can be read against the warm/cold split.
  ///
  /// Called from the capture step, so the checkpoint is taken the moment
  /// capture is *proven* live rather than when it was requested.
  static func recordCaptureStart(for session: ActiveSession, recording: RecordingStart, logger: Logger) {
    let nowUptime = ProcessInfo.processInfo.systemUptime
    let liveUptime = min(recording.liveUptime ?? nowUptime, nowUptime)
    session.captureStarted = Date().addingTimeInterval(liveUptime - nowUptime)
    session.captureStartedUptime = liveUptime
    session.recorderOpenMilliseconds = recording.recorderOpenMilliseconds
    if let coldStartMs = session.captureStartMilliseconds {
      let path = recording.usedWarmRecorder ? "pre-warmed" : "cold"
      logger.info("Latency: capture started \(coldStartMs)ms after trigger (\(path, privacy: .public))")
    }
    if let keyDownMs = session.keyDownToCaptureMilliseconds {
      logger.info("Latency: capture started \(keyDownMs)ms after key-down")
    }
  }

  /// Records the full start timeline (capture, streaming tap, cue) in history
  /// so a clipped-start report can be diagnosed from the session alone
  /// (issue #641).
  static func recordStartTimeline(_ timeline: RecordingStartTimeline, for session: ActiveSession, logger: Logger) {
    var summary = timeline.diagnosticSummary
    guard !summary.isEmpty else { return }
    if let recorderOpenMs = session.recorderOpenMilliseconds {
      summary += ", recorder open \(SessionLatencyMetrics.formattedMilliseconds(recorderOpenMs))"
    }
    logger.info("Recording start timeline: \(summary, privacy: .public)")
    session.events.append(HistoryEvent(kind: .recordingStarted, description: "Start timeline — \(summary)"))
  }

  /// Logs key-down → capture and key-down → first primed audio, and keeps
  /// them on the session for diagnosis.
  private func recordKeyDownLatency(for session: ActiveSession, primedInput: PrimedLiveInputReservation?) async {
    guard let keyDownMs = session.keyDownToCaptureMilliseconds else { return }
    var summary = "capture \(keyDownMs)ms after key-down"
    if let primed = await primedInput?.value {
      let warmUpMs = Int(((primed.startedUptime - primed.keyDownUptime) * 1000).rounded())
      summary += ", microphone warmed at key-down (running at \(warmUpMs)ms"
      if let signalMs = primed.firstSignalMilliseconds {
        summary += ", first audio at \(signalMs)ms)"
      } else {
        summary += ", no audio before hand-over)"
      }
    }
    logger.info("Latency: \(summary, privacy: .public)")
    session.events.append(HistoryEvent(kind: .recordingStarted, description: "Key-down timeline — \(summary)"))
  }
}
