import AVFoundation
import Combine
import Foundation

/// Monitors audio levels from an AVAudioRecorder and publishes normalized levels at ~30fps.
/// Note: This class is provided for reference but the actual level monitoring is handled
/// by MainManager polling AudioFileManager.getCurrentAudioLevel() directly.
@MainActor
final class AudioLevelMonitor: ObservableObject {
    /// Normalized audio level from 0.0 (silence) to 1.0 (peak/clipping)
    @Published private(set) var level: Float = 0

    private var recorder: AVAudioRecorder?
    private var isMonitoring = false
    private var pollingTimer: Timer?

    /// Smoothing factor for level transitions (higher = smoother but more latent)
    private let smoothingFactor: Float = 0.3

    /// Start monitoring audio levels from the given recorder.
    /// The recorder must have `isMeteringEnabled = true`.
    func startMonitoring(recorder: AVAudioRecorder) {
        guard !isMonitoring else { return }
        self.recorder = recorder
        isMonitoring = true

        // Poll at ~30fps (33ms interval)
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateLevel()
            }
        }
        if let timer = pollingTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// Stop monitoring audio levels.
    func stopMonitoring() {
        isMonitoring = false
        pollingTimer?.invalidate()
        pollingTimer = nil
        recorder = nil
        level = 0
    }

    private func updateLevel() {
        guard isMonitoring, let recorder = recorder else {
            level = 0
            return
        }

        recorder.updateMeters()

        // Get average power in decibels (typically -160 to 0)
        let averagePower = recorder.averagePower(forChannel: 0)
        let peakPower = recorder.peakPower(forChannel: 0)

        // Use a combination of average and peak for a more responsive meter
        let combinedPower = (averagePower * 0.7) + (peakPower * 0.3)

        // Convert decibels to normalized linear scale (0.0 to 1.0)
        // -60 dB = silence threshold, 0 dB = maximum
        let minDb: Float = -60
        let normalizedLevel = max(0, min(1, (combinedPower - minDb) / (-minDb)))

        // Apply smoothing for less jittery animation
        let smoothedLevel = (smoothingFactor * normalizedLevel) + ((1 - smoothingFactor) * level)

        level = smoothedLevel
    }
}
