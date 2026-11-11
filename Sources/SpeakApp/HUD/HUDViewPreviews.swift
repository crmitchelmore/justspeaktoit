import SpeakCore
import SwiftUI

struct HUDOverlay_Previews: PreviewProvider {
  static var previews: some View {
    Group {
      // Compact preview
      preview(previewManager, name: "Compact")

      // Compact with a long local-model label (worst case for the metadata row)
      preview(localModelPreviewManager, name: "Compact – Long Local Model")

      // Same content squeezed into a narrow window
      preview(localModelPreviewManager, name: "Compact – Narrow", width: 360)

      // Dark appearance
      preview(localModelPreviewManager, name: "Compact – Dark")
        .preferredColorScheme(.dark)

      // Failure state with capture-health row
      preview(failurePreviewManager, name: "Failure")

      // Expanded with transcript
      preview(expandedPreviewManager, name: "Expanded with Transcript", height: 500)
    }
  }

  private static func preview(
    _ manager: HUDManager,
    name: String,
    width: CGFloat = 600,
    height: CGFloat = 400
  ) -> some View {
    HUDOverlay(manager: manager)
      .environmentObject(AppSettings())
      .frame(width: width, height: height)
      .previewDisplayName(name)
  }

  private static var previewManager: HUDManager {
    let manager = HUDManager(appSettings: AppSettings())
    manager.beginRecording()
    manager.updateCaptureHealth(
      CaptureHealthSnapshot(
        microphonePermission: .granted,
        noInputDevicesAvailable: false,
        inputDeviceName: "MacBook Pro Microphone",
        providerLabel: "Deepgram Nova-3 (Streaming)",
        latencyTier: .fast
      )
    )
    manager.updateLiveTranscription(
      text: "Testing the compact heads-up display with a short partial transcript",
      isFinal: false,
      confidence: 0.94
    )
    return manager
  }

  private static var localModelPreviewManager: HUDManager {
    let manager = HUDManager(appSettings: AppSettings())
    manager.beginRecording()
    manager.updateCaptureHealth(
      CaptureHealthSnapshot(
        microphonePermission: .granted,
        noInputDevicesAvailable: false,
        inputDeviceName: "External USB Interface Microphone",
        providerLabel: "Sherpa Onnx Streaming Zipformer En 2023 06 26",
        latencyTier: .instant
      )
    )
    manager.updateLiveTranscription(
      text: "The quick brown fox jumps over the lazy dog while the local model keeps streaming new words in",
      isFinal: false,
      confidence: 0.87
    )
    return manager
  }

  private static var failurePreviewManager: HUDManager {
    let manager = HUDManager(appSettings: AppSettings())
    manager.updateCaptureHealth(
      CaptureHealthSnapshot(
        microphonePermission: .granted,
        noInputDevicesAvailable: true,
        inputDeviceName: "Unknown",
        providerLabel: "Whisper Large v3 Turbo (Streaming)",
        latencyTier: .medium
      )
    )
    manager.finishFailure(
      headline: "Something went wrong",
      message: "No audio was captured from the microphone",
      showRetryHint: true,
      displayDuration: 0
    )
    return manager
  }

  private static var expandedPreviewManager: HUDManager {
    let manager = HUDManager(appSettings: AppSettings())
    manager.beginRecording()
    manager.updateCaptureHealth(
      CaptureHealthSnapshot(
        microphonePermission: .granted,
        noInputDevicesAvailable: false,
        inputDeviceName: "MacBook Pro Microphone",
        providerLabel: "Distil-Whisper Large v3 Turbo (Streaming)",
        latencyTier: .fast
      )
    )
    manager.updateLiveTranscription(
      text: "Hello, this is a test of the live transcription feature. It should scroll and show "
        + "the text properly. And this is still being spoken...",
      isFinal: false,
      confidence: 0.92
    )
    manager.isExpanded = true
    return manager
  }
}
