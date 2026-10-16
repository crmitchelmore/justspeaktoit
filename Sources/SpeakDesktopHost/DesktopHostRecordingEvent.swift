import Foundation
import SpeakCore
import SpeakDesktop

/// Read in native settings order, without opening capture or granting consent.
package struct DesktopHostRecordingEvent<Platform: DesktopHostPlatform>: Sendable {
    package let profile: DesktopProfileSession
    package let textOutput: Platform.TextOutputOptions
    let configuration: DesktopConfiguration?
}

extension DesktopHostController {
    package func captureRecordingEvent(
        modelIndex: Int?, executablePath: String?
    ) -> DesktopHostRecordingEvent<Platform> {
        .init(
            profile: captureProfile(modelIndex: modelIndex, executablePath: executablePath),
            textOutput: textOutputOptions(), configuration: settings.configuration
        )
    }

    /// Recovery text is still History, not a successful automation completion.
    package func completedDictationRecord(_ id: UUID) throws -> DesktopRecordingStore.Record {
        guard dictationSessionID != id else {
            throw AutomationError(
                code: .internalError, message: "Capture retirement is incomplete; audio remains owned."
            )
        }
        guard let record = history[id] else {
            throw AutomationError(
                code: .transcriptionFailed,
                message: "Dictation ended before capture was ready; no transcript was produced."
            )
        }
        if let failure = record.failure ?? record.postProcessingFailure {
            throw AutomationError(code: .transcriptionFailed, message: failure)
        }
        guard record.result != nil else {
            throw AutomationError(code: .transcriptionFailed, message: "History has no completed dictation transcript.")
        }
        return record
    }
}
