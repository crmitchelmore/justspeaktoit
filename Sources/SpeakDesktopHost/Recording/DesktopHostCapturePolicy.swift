import Foundation
import SpeakCore
import SpeakDesktop

/// A present policy with nil configuration uses defaults, not later settings.
struct DesktopHostCapturePolicy: Sendable {
    let configuration: DesktopConfiguration?

    var tailSeconds: TimeInterval {
        configuration?.number("postRecordingTailDuration") ?? SpeechDefaults.recordingTailDuration
    }
}

struct DesktopHostRecordingStart<Platform: DesktopHostPlatform> {
    let target: Platform.InsertionTarget?
    let deviceID: String
    let profile: DesktopProfileSession
    let textOutput: Platform.TextOutputOptions
    let trigger: HotKeySessionTrigger
    let handsFree: DesktopHandsFreeRun<Platform>?
    let capturePolicy: DesktopHostCapturePolicy?
    /// Explains a per-utterance profile fallback in the recording's History.
    var profileNotice: String?
}

extension DesktopHostController {
    func recordingTailSeconds(recordID: UUID) -> TimeInterval? {
        guard let policy = recordingCapturePolicy, policy.recordID == recordID,
              recording?.record.id == recordID else { return nil }
        return policy.value.tailSeconds
    }
}
