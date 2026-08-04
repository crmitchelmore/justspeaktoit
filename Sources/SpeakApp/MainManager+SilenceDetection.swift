import SpeakCore
import AppKit
import Foundation
import os.log

extension MainManager {
  func startAudioLevelMonitoring() {
    audioLevelTimer?.invalidate()
    silenceStartTime = nil
    
    // Cache silence detection settings to avoid repeated @Published property access
    // during high-frequency timer callbacks (30Hz)
    cachedSilenceEnabled = appSettings.silenceDetectionEnabled
    cachedSilenceThreshold = appSettings.silenceThreshold
    cachedSilenceDuration = appSettings.silenceDuration
    
    // Track HUD visibility to skip UI updates when app is occluded
    isHUDOccluded = !(NSApp.occlusionState.contains(.visible))
    occlusionObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeOcclusionStateNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.isHUDOccluded = !(NSApp.occlusionState.contains(.visible))
    }

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
    let level = audioFileManager.getCurrentAudioLevel()
    // Only push UI updates when the HUD is likely visible
    if !isHUDOccluded {
      hudManager.updateAudioLevel(level)
    }
    checkSilenceDetection(
      level: level,
      enabled: cachedSilenceEnabled,
      threshold: cachedSilenceThreshold,
      duration: cachedSilenceDuration
    )
  }

  private func checkSilenceDetection(level: Float, enabled: Bool, threshold: Float, duration: TimeInterval) {
    guard enabled else {
      silenceStartTime = nil
      return
    }
    guard state == .recording, activeSession != nil else {
      silenceStartTime = nil
      return
    }

    let isSilent = level < threshold

    if isSilent {
      if silenceStartTime == nil {
        silenceStartTime = Date()
      } else if let startTime = silenceStartTime {
        let silentDuration = Date().timeIntervalSince(startTime)
        if silentDuration >= duration {
          logger.info("Auto-stopping recording after \(silentDuration, privacy: .public)s of silence")
          SentryManager.addBreadcrumb(
            category: "recording",
            message: "Silence auto-stop after \(String(format: "%.1f", silentDuration))s"
          )
          silenceStartTime = nil
          Task {
            await endSession(trigger: .silenceDetection)
          }
        }
      }
    } else {
      // Reset silence timer when audio is detected
      silenceStartTime = nil
    }
  }

  func stopAudioLevelMonitoring() {
    audioLevelTimer?.invalidate()
    audioLevelTimer = nil
    silenceStartTime = nil
    isHUDOccluded = false
    if let observer = occlusionObserver {
      NotificationCenter.default.removeObserver(observer)
      occlusionObserver = nil
    }
    hudManager.updateAudioLevel(0)
  }
}
