import SpeakCore
import AVFoundation
import AppKit
import Foundation

/// Admission checks and the start sequence for a new dictation session.
extension MainManager {
  /// Checks that must pass before a session exists. Returns the rejection
  /// after undoing the profile and warm-capture hand-off, or nil when the
  /// start may proceed with `.dictation` capture reserved.
  func rejectionBeforeStart(trigger: SessionTriggerSource) async -> HandsFreeCaptureStartOutcome? {
    if trigger == .handsFree,
      !HandsFreeDictationPolicy.supportsCapture(
        modelID: appSettings.liveTranscriptionModel,
        isStreaming: appSettings.transcriptionMode == .liveNative
      ) {
      return abandonStart(.rejected(.unsupportedConfiguration))
    }

    if await presentMissingLiveAPIKeyAlertIfNeeded() {
      return abandonStart(.rejected(.captureFailed))
    }

    if audioFileManager.requiresPhysicalInput && audioInputDeviceManager.devices.isEmpty {
      let rejection = abandonStart(.rejected(.audioUnavailable))
      showStartFailure(
        "No microphone connected. Plug in a USB or Bluetooth microphone and try again.",
        headline: "No microphone connected",
        message: "Plug in a USB or Bluetooth microphone and try again."
      )
      return rejection
    }

    // Voice Edit may own the shared recorder and live stream right now. Starting
    // on top of it would hit `alreadyRecording` and the failure path would then
    // cancel Voice Edit's capture, so refuse before touching either (issue #673).
    guard captureOwnership.reserve(.dictation) else {
      let rejection = abandonStart(.rejected(.captureFailed))
      showStartFailure(
        "Voice edit is in progress. Finish or cancel it first.",
        headline: "Voice edit in progress",
        message: "Finish or cancel the voice edit, then start dictation.",
        displayDuration: 3
      )
      return rejection
    }
    return nil
  }

  /// No session was created, so `activeSession`'s teardown will not run:
  /// revert the profile and let capture pre-warming resume here.
  private func abandonStart(_ rejection: HandsFreeCaptureStartOutcome) -> HandsFreeCaptureStartOutcome {
    sessionRetirement.abandonStart()
    return rejection
  }

  private func showStartFailure(
    _ stateMessage: String,
    headline: String,
    message: String,
    displayDuration: TimeInterval? = nil
  ) {
    state = .failed(stateMessage)
    lastErrorMessage = stateMessage
    hudManager.finishFailure(headline: headline, message: message, displayDuration: displayDuration)
  }

  /// Brings up capture (and the live stream) for a session that now exists,
  /// then plays the start cue. Abandons quietly if the session ended meanwhile.
  func runStartSequence(
    for session: ActiveSession,
    trigger: SessionTriggerSource,
    preRollBuffers: [AVAudioPCMBuffer],
    primedInput: PrimedLiveInputReservation?
  ) async -> HandsFreeCaptureStartOutcome {
    // Claim the recorder staged while idle. Returns nil — and the cold path
    // runs — whenever the environment moved since it was staged.
    let warmContext = captureWarmer?.claimWarmContext()
    let liveInputPreparation = LiveInputPreparation(
      deviceManager: audioInputDeviceManager,
      engines: LiveInputEngines.shared,
      primed: primedInput
    )

    do {
      // Issue #641: the start cue is played by the sequencer *after* capture is
      // proven live (and, in streaming modes, after the audio tap is running),
      // so the user is never invited to speak into a microphone that isn't
      // listening yet. The pre-warm path (issue #663) runs inside the same
      // step — a claimed staged recorder still has to prove it is capturing.
      let startStream = makeStartStreamStep(
        for: session, trigger: trigger, preRollBuffers: preRollBuffers, primedInput: primedInput
      )
      // The live engine's input node is built before the recorder opens the
      // microphone; built afterwards it stalled stream start (and the cue) by
      // ~3 s on Bluetooth inputs. See `LiveInputEngineStore`. Routes that
      // capture through their own engine (WhisperKit) would never claim it.
      let prepareStream: RecordingStartSequencer.Step? = audioFileManager.requiresPhysicalInput
        && transcriptionManager.liveRouteUsesLiveInputEngine
        ? { await liveInputPreparation.prepare() }
        : nil
      if let primedInput, prepareStream == nil {
        // This route builds its own input node (or none); it must not do so
        // beside the primer's open microphone.
        await keyPressPrimer.closeBeforeStart(primedInput)
      }
      let showsHUD = showRecordingHUDIfNeeded(for: trigger)
      let sequencer = RecordingStartSequencer(
        isSessionCurrent: { [weak self] in self?.activeSession === session },
        prepareStream: prepareStream,
        discardPreparedStream: { await liveInputPreparation.finish(startFailed: true) },
        startCapture: makeStartCaptureStep(for: session, warmContext: warmContext, showsHUD: showsHUD),
        discardCapture: { [weak self] in await self?.discardStartedCapture() },
        startStream: startStream,
        discardStream: { [weak self] in self?.transcriptionManager.cancelLiveTranscription() },
        playCue: { [weak self] in self?.requestRecordingStartCue(for: session) }
      )
      let timeline = try await sequencer.run()
      await liveInputPreparation.finish()
      recordStartTimeline(for: session, timeline: timeline)
      await recordKeyDownLatency(for: session, primedInput: primedInput)
      return .started
    } catch is RecordingStartAbort {
      await liveInputPreparation.finish(startFailed: true)
      hudManager.cancelAwaitingAudio()
      // Not a failure: the session ended while startup was suspended, and the
      // sequencer has already torn down whatever it brought up. Touching the
      // shared failure path here would clobber the session that replaced it.
      logger.info("Recording start abandoned: the session ended before capture was ready")
      return .rejected(.captureFailed)
    } catch {
      await liveInputPreparation.finish(startFailed: true)
      return failStart(of: session, error: error)
    }
  }

  private func failStart(of session: ActiveSession, error: Error) -> HandsFreeCaptureStartOutcome {
    guard sessionProcessingShouldContinue(session) else { return .rejected(.captureFailed) }
    session.errors.append(
      HistoryError(
        phase: .recording,
        message: "Failed to start recording",
        debugDescription: error.localizedDescription
      )
    )
    cleanupAfterFailure(message: error.localizedDescription, preserveFile: false)
    return .rejected(HandsFreeDictationMachine.Failure(error))
  }

  /// Returns true (and sets `missingLiveAPIKeyAlert`) when the chosen live
  /// transcription model needs an API key that has not been stored. Callers
  /// should abort the session start when this returns true.
  func presentMissingLiveAPIKeyAlertIfNeeded() async -> Bool {
    guard appSettings.transcriptionMode == .liveNative else { return false }
    guard let missing = await transcriptionManager.missingLiveAPIKeyProvider() else {
      return false
    }
    let modelID = appSettings.liveTranscriptionModel
    let modelName = ModelCatalog.liveTranscription.first { $0.id == modelID }?.displayName ?? modelID
    missingLiveAPIKeyAlert = MissingLiveAPIKeyAlert(
      provider: missing,
      modelDisplayName: modelName
    )
    return true
  }

  func rawTranscriptionSubheadline() -> String {
    guard appSettings.transcriptionMode == .localModel else {
      return "Preparing raw transcript"
    }
    if LocalModelManager.shared.isModelLoaded(appSettings.localTranscriptionModel) {
      return "Transcribing locally on this Mac"
    }
    return "Loading local model and transcribing. First run can take a minute."
  }
}
