#if os(iOS)
import SpeakCore
import UIKit

/// Effects used by the headless recording owner. Tests can replace every
/// activity operation together, including completion, without touching ActivityKit.
@MainActor
struct RecordingServiceActivity {
    typealias Status = TranscriptionActivityAttributes.TranscriptionStatus

    var start: (String, Status) -> Bool
    var update: (Status, String, Int, Int) -> Void
    var endActivity: () -> Void
    var reportError: (String) -> Void
    var complete: TranscriptionRecordingService.ActivityCompletion
    var hasActiveResult: (String) -> Bool = { _ in false }

    func startActivity(provider: String, initialStatus: Status) -> Bool {
        self.start(provider, initialStatus)
    }

    func updateActivity(status: Status, lastSnippet: String, wordCount: Int, duration: Int) {
        self.update(status, lastSnippet, wordCount, duration)
    }

    static func live(_ manager: TranscriptionActivityManager) -> Self {
        Self(
            start: { manager.startActivity(provider: $0, initialStatus: $1) },
            update: { manager.updateActivity(status: $0, lastSnippet: $1, wordCount: $2, duration: $3) },
            endActivity: { manager.endActivity() },
            reportError: { manager.reportError($0) },
            complete: { count, duration, primedMessage, outcome, preview, message, identifier in
                manager.completeActivity(
                    finalWordCount: count,
                    duration: duration,
                    keepPrimed: true,
                    primedMessage: primedMessage,
                    completionOutcome: outcome,
                    resultPreview: preview,
                    completionMessage: message,
                    resultCompletionID: identifier
                )
            },
            hasActiveResult: { manager.hasActiveResult(completionID: $0) }
        )
    }
}

/// Missing collaborators in the recording service's existing initializer seam.
/// Production defaults are resolved only when the service is constructed; mutable
/// settings and application state are still read at the phase that needs them.
@MainActor
struct RecordingServiceDependencies {
    let settings: AppSettings
    let activity: RecordingServiceActivity
    let keyboardDelivery: KeyboardDeliveryStore
    let recordDictation: (CaptureTrigger, String) -> Void
    let markDelivered: (UUID) -> Void
    let applicationState: () -> UIApplication.State
    var notifyTranscriptReady: (TranscriptReadyNotificationInput) -> Void = { _ in }

    static func live(settings: AppSettings = .shared) -> Self {
        Self(
            settings: settings,
            activity: .live(.shared),
            keyboardDelivery: .shared,
            recordDictation: { CaptureOnboardingStore.shared.recordDictation(trigger: $0, transcript: $1) },
            markDelivered: { CaptureSafetyClaimStore.shared.markDelivered(recording: $0) },
            applicationState: { UIApplication.shared.applicationState },
            notifyTranscriptReady: { TranscriptReadyNotificationCoordinator.shared.submit($0) }
        )
    }
}
#endif
