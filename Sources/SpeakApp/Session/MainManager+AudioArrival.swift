import Foundation
import os.log

/// The HUD clock and the start cue wait for the microphone to deliver real
/// audio (see `RecordingAudioArrivalGate`): the pane appears as "Getting ready"
/// as soon as the session starts, and only starts counting once words could be
/// heard.
extension MainManager {
  /// Arms the gate once capture is running.
  func beginAwaitingAudio(for session: ActiveSession) {
    audioArrivalGate = RecordingAudioArrivalGate(captureStarted: Date())
    audioArrivalSession = session
  }

  /// Feeds one meter reading from the level timer.
  func observeAudioArrival(peakDecibels: Float?) {
    guard var gate = audioArrivalGate, let session = audioArrivalSession else { return }
    let actions = gate.observe(peakDecibels: peakDecibels, at: Date())
    audioArrivalGate = gate
    guard !actions.isEmpty else { return }
    if actions.contains(.startClock) {
      hudManager.markAudioLive()
      logAudioArrival(for: session, arrival: gate.arrival)
    }
    apply(actions, for: session)
  }

  /// The start sequence reached its cue step. Without an armed gate (nothing
  /// is metering this session) the cue plays straight away, as it always did.
  func requestRecordingStartCue(for session: ActiveSession) {
    guard var gate = audioArrivalGate, audioArrivalSession === session else {
      playRecordingStartCue(for: session)
      return
    }
    let actions = gate.requestCue()
    audioArrivalGate = gate
    apply(actions, for: session)
  }

  func endAwaitingAudio() {
    audioArrivalGate = nil
    audioArrivalSession = nil
  }

  private func apply(_ actions: RecordingAudioArrivalGate.Actions, for session: ActiveSession) {
    if actions.contains(.playCue) {
      playRecordingStartCue(for: session)
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
