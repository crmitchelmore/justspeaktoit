import SpeakCore
import AppKit
import Foundation
import os.log

extension MainManager {
  func startAudioLevelMonitoring() {
    audioLevelTimer?.invalidate()
    // Cache silence detection settings to avoid repeated @Published property access
    // during high-frequency timer callbacks (30Hz)
    silenceAutoStop.begin(
      SilenceAutoStop.Settings(
        enabled: appSettings.silenceDetectionEnabled,
        threshold: appSettings.silenceThreshold,
        duration: appSettings.silenceDuration
      )
    )
    // Track HUD visibility to skip UI updates when app is occluded
    hudOcclusion.start()

    // Use target-selector Timer pattern to completely bypass Swift concurrency runtime.
    // Block-based timers with [weak self] can crash in swift_getObjectType during
    // executor verification if the object is deallocating.
    audioLevelTimer = Timer.scheduledTimer(
      timeInterval: 1.0 / 30.0,
      target: self,
      selector: #selector(audioLevelTimerFired),
      userInfo: nil,
      repeats: true
    )
    if let timer = audioLevelTimer {
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  @objc private func audioLevelTimerFired() {
    // This runs on main thread via RunLoop.main. No Swift concurrency checks.
    guard state == .recording else { return }
    let reading = audioFileManager.getCurrentMeterReading()
    let level = reading?.level ?? 0
    if audioArrivalGate != nil {
      observeAudioArrival(peakDecibels: reading?.peakDecibels)
    }
    // Only push UI updates when the HUD is likely visible
    if !hudOcclusion.isOccluded {
      hudManager.updateAudioLevel(level)
    }
    // Hands-free captures end on the speech detector's own silence hold. Two
    // owners of the same stop race each other, and the loser then reports a
    // failed session after every utterance, so level-based auto-stop stays out.
    let eligible = activeSession.map { $0.trigger != .handsFree } ?? false
    if let silentDuration = silenceAutoStop.observe(level: level, eligible: eligible) {
      logger.info("Auto-stopping recording after \(silentDuration, privacy: .public)s of silence")
      SentryManager.addBreadcrumb(
        category: "recording",
        message: "Silence auto-stop after \(String(format: "%.1f", silentDuration))s"
      )
      Task {
        await endSession(trigger: .silenceDetection)
      }
    }
  }

  func stopAudioLevelMonitoring() {
    audioLevelTimer?.invalidate()
    audioLevelTimer = nil
    silenceAutoStop.reset()
    endAwaitingAudio()
    hudOcclusion.stop()
    hudManager.updateAudioLevel(0)
  }
}
