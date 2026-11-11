import SpeakCore
import AVFoundation
import AppKit
import Foundation

/// Stopping a recording and handing it to transcription, post-processing
/// and delivery.
extension MainManager {
  enum SessionStopError: LocalizedError {
    case recordingStopTimedOut(seconds: TimeInterval)

    var errorDescription: String? {
      switch self {
      case .recordingStopTimedOut(let seconds):
        let timeout = String(format: "%.0f", seconds)
        return "Stopping recording took too long (\(timeout)s timeout)."
      }
    }
  }

  /// Plays the stop cue, moves to processing and records the stop in History.
  private func markRecordingStopped(
    _ session: ActiveSession,
    trigger: SessionTriggerSource,
    tailDuration: TimeInterval
  ) {
    if appSettings.recordingSoundsEnabled {
      recordingSoundPlayer.play(.stop, volume: appSettings.recordingSoundVolume)
    }

    state = .processing
    session.recordingEnded = Date()
    if isStreamingTranscriptionMode {
      // Move the HUD off the "Recording" timer immediately. Otherwise the
      // user sees the recording timer frozen at the release time while we
      // close the audio file and drain the live provider's finalisation
      // budget — which on AssemblyAI can be ~2s and reads as a hang for
      // very short presses where the WebSocket `Begin` never arrived.
      hudManager.beginTranscribing(subheadline: "Finalising transcript")
    }
    var stopDescription = "Recording stopped via \(trigger.historyGesture.rawValue)"
    if tailDuration > 0 {
      stopDescription += " (tail +\(String(format: "%.1f", tailDuration))s)"
    }
    session.events.append(
      HistoryEvent(
        kind: .recordingStopped,
        timestamp: Date(),
        description: stopDescription
      )
    )
  }

  func endSession(trigger: SessionTriggerSource) async {
    guard let session = activeSession, captureRuntime.beginEnding() else { return }
    defer { captureRuntime.finishEnding() }

    // Latency checkpoint: user asked to stop (before the optional tail sleep).
    session.stopRequested = Date()

    captureRuntime.stop()

    let tailDuration = max(appSettings.postRecordingTailDuration, 0)
    if tailDuration > 0 {
      do {
        try await Task.sleep(nanoseconds: UInt64(tailDuration * 1_000_000_000))
      } catch {
        // Ignored: sleep cancellation simply means we stop immediately.
      }
    }
    guard sessionProcessingShouldContinue(session) else { return }

    markRecordingStopped(session, trigger: trigger, tailDuration: tailDuration)

    do {
      let summary = try await stopRecordingWithTimeout()
      guard sessionProcessingShouldContinue(session) else { return }
      session.recordingSummary = summary
      session.recordingEnded = summary.startedAt.addingTimeInterval(summary.duration)

      let transcribed = isStreamingTranscriptionMode
        ? try await finishLiveTranscription(for: session)
        : try await transcribeRecording(summary, for: session)
      guard transcribed else { return }
      let correctedText = text.applyVoiceCommandsAndLexicon(to: session.transcriptionResult?.text ?? "", for: session)
      guard let processed = await postProcessIfNeeded(correctedText, for: session) else { return }
      await deliver(processed.text, postProcessingFailure: processed.failureMessage, for: session)
    } catch {
      guard sessionProcessingShouldContinue(session) else { return }
      session.errors.append(
        HistoryError(
          phase: .transcription,
          message: "Processing failed",
          debugDescription: error.localizedDescription
        )
      )
      cleanupAfterFailure(message: error.localizedDescription, preserveFile: true)
    }
  }
}
