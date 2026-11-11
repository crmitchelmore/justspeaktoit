import Foundation
import SpeakCore
import os.log

/// Owns the facts of the recording that is capturing right now: the 30 Hz
/// level timer, level-based silence auto-stop, HUD occlusion, the audio-arrival
/// gate that holds the HUD clock and start cue until the microphone delivers
/// real audio, and whether a stop is under way.
///
/// `begin(_:)` arms it for one session once capture is live and `stop()`
/// disarms all of it. The arrival gate is bound to that session, so a cue
/// request for any other session plays straight away instead of touching it.
@MainActor
final class SessionCaptureRuntime: NSObject {
  /// What the runtime reads and reports. Closures keep it free of the
  /// recorder, the HUD and the session façade.
  struct Context {
    /// The recorder's current level and peak, nil when nothing records.
    var meterReading: () -> (level: Float, peakDecibels: Float)?
    /// Read once per recording, never on the 30 Hz path.
    var silenceSettings: () -> SilenceAutoStop.Settings
    var isRecording: () -> Bool
    /// False for hands-free captures: their speech detector owns the stop.
    var silenceStopEligible: () -> Bool
    var updateAudioLevel: (Float) -> Void
    var markAudioLive: () -> Void
    /// Plays the start cue for a session that still records.
    var playCue: (ActiveSession) -> Void
    /// The input has been silent long enough to stop the recording.
    var silenceElapsed: () -> Void
  }

  /// True from the moment a stop starts until it returns, so a silence stop
  /// and a hotkey stop never both run.
  private(set) var isEnding = false
  private(set) var isMonitoring = false
  private var timer: Timer?
  private var silenceAutoStop = SilenceAutoStop()
  private var arrivalGate: RecordingAudioArrivalGate?
  private weak var arrivalSession: ActiveSession?
  private let hudOcclusion: HUDOcclusionObserver
  private let context: Context
  private let schedulesTimer: Bool
  private let logger = SpeakLogger.logger(category: "SessionCaptureRuntime")

  /// `schedulesTimer` is false only in tests, which drive `tick(now:)`.
  init(context: Context, hudOcclusion: HUDOcclusionObserver? = nil, schedulesTimer: Bool = true) {
    self.context = context
    self.hudOcclusion = hudOcclusion ?? HUDOcclusionObserver()
    self.schedulesTimer = schedulesTimer
  }

  /// Arms the arrival gate for `session` and starts metering.
  func begin(_ session: ActiveSession, captureStarted: Date = Date()) {
    arrivalGate = RecordingAudioArrivalGate(captureStarted: captureStarted)
    arrivalSession = session
    timer?.invalidate()
    timer = nil
    silenceAutoStop.begin(context.silenceSettings())
    hudOcclusion.start()
    isMonitoring = true
    guard schedulesTimer else { return }
    // A target-selector timer bypasses the Swift concurrency runtime: a
    // block-based timer with [weak self] can crash in swift_getObjectType
    // during executor verification while the owner deallocates.
    let timer = Timer(
      timeInterval: 1.0 / 30.0,
      target: self,
      selector: #selector(timerFired),
      userInfo: nil,
      repeats: true
    )
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  /// Stops metering and forgets the arrival gate and any pending silence.
  func stop() {
    timer?.invalidate()
    timer = nil
    isMonitoring = false
    silenceAutoStop.reset()
    endAwaitingAudio()
    hudOcclusion.stop()
    context.updateAudioLevel(0)
  }

  /// Claims the stop. Returns false when another stop is already running;
  /// otherwise the caller must call `finishEnding()` when it returns.
  func beginEnding() -> Bool {
    guard !isEnding else { return false }
    isEnding = true
    return true
  }

  func finishEnding() {
    isEnding = false
  }

  /// The start sequence reached its cue step. Without a gate armed for this
  /// session (nothing meters it) the cue plays straight away.
  func requestStartCue(for session: ActiveSession) {
    guard var gate = arrivalGate, arrivalSession === session else {
      context.playCue(session)
      return
    }
    let actions = gate.requestCue()
    arrivalGate = gate
    apply(actions, for: session)
  }

  @objc private func timerFired() {
    // Runs on the main run loop, outside Swift concurrency checks.
    tick()
  }

  /// One meter reading: arrival, the HUD level and silence auto-stop.
  func tick(now: Date = Date()) {
    guard context.isRecording() else { return }
    let reading = context.meterReading()
    let level = reading?.level ?? 0
    if arrivalGate != nil {
      observeArrival(peakDecibels: reading?.peakDecibels, now: now)
    }
    if !hudOcclusion.isOccluded {
      context.updateAudioLevel(level)
    }
    let eligible = context.silenceStopEligible()
    if let silentDuration = silenceAutoStop.observe(level: level, eligible: eligible, now: now) {
      logger.info("Auto-stopping recording after \(silentDuration, privacy: .public)s of silence")
      SentryManager.addBreadcrumb(
        category: "recording",
        message: "Silence auto-stop after \(String(format: "%.1f", silentDuration))s"
      )
      context.silenceElapsed()
    }
  }

  private func observeArrival(peakDecibels: Float?, now: Date) {
    guard var gate = arrivalGate, let session = arrivalSession else { return }
    let actions = gate.observe(peakDecibels: peakDecibels, at: now)
    arrivalGate = gate
    guard !actions.isEmpty else { return }
    if actions.contains(.startClock) {
      context.markAudioLive()
      logAudioArrival(for: session, arrival: gate.arrival)
    }
    apply(actions, for: session)
  }

  private func endAwaitingAudio() {
    arrivalGate = nil
    arrivalSession = nil
  }

  private func apply(_ actions: RecordingAudioArrivalGate.Actions, for session: ActiveSession) {
    guard actions.contains(.playCue) else { return }
    context.playCue(session)
    // The start timeline's "cue" stage marks when the sequence asked for the
    // cue; the gate may have held it until audio arrived, so record playback.
    if let captureUptime = session.captureStartedUptime {
      let playedMs = Int(((ProcessInfo.processInfo.systemUptime - captureUptime) * 1000).rounded())
      logger.info("Latency: start cue played \(playedMs)ms after capture start")
      session.events.append(
        HistoryEvent(kind: .recordingStarted, description: "Start cue played \(playedMs)ms after capture start")
      )
    }
    // Arrival and the cue are both done; nothing is left to gate.
    endAwaitingAudio()
  }

  private func logAudioArrival(for session: ActiveSession, arrival: RecordingAudioArrivalGate.Arrival?) {
    let uptime = ProcessInfo.processInfo.systemUptime
    let reason = arrival == .fallback ? "fallback, input still silent" : "signal"
    var summary = "audio live"
    if let keyDownMs = session.millisecondsSinceKeyDown(to: uptime) {
      summary += " \(keyDownMs)ms after key-down"
    }
    if let captureUptime = session.captureStartedUptime {
      summary += " (\(Int(((uptime - captureUptime) * 1000).rounded()))ms after capture start)"
    }
    summary += " [\(reason)]"
    logger.info("Latency: \(summary, privacy: .public)")
    session.events.append(HistoryEvent(kind: .recordingStarted, description: "Audio arrival — \(summary)"))
  }
}
