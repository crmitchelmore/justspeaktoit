#if os(iOS)
import AppIntents
import SpeakCore
import UIKit

// MARK: - Audio Recording Intent (Action Button / Shortcuts)

@available(iOS 18, *)
private func stopResultDialog(
    for result: TranscriptionResult,
    destination: HardwareTriggerDestination,
    canPostProcess: Bool = true
) -> IntentDialog {
    let wordCount = result.text.split(separator: " ").count
    if result.text.isEmpty {
        return "Recording stopped. No speech detected."
    }
    switch destination {
    case .clipboard:
        return "Copied \(wordCount) words to clipboard."
    case .clipboardAndPostProcess:
        if canPostProcess {
            return "Copied \(wordCount) words. Polishing in the background."
        }
        return "Copied \(wordCount) words. Add an OpenRouter API key to polish future recordings."
    case .historyOnly:
        return "Saved \(wordCount) words to history."
    }
}

/// Starts recording, transparently recovering when the *background* Live Activity
/// can't be started.
///
/// When the Action Button / a Shortcut / Siri launches the app in the background,
/// ActivityKit refuses to start a Live Activity (`Activity.request` throws), so
/// `startRecording()` reports `iOSTranscriptionError.liveActivityUnavailable`
/// rather than record without the mandatory Live Activity (which the AppIntents
/// system-policy check would kill). Previously the user just saw a "turn on Live
/// Activities" error even when they *were* enabled.
///
/// Here we recover by continuing in the foreground: the app briefly comes to the
/// front, where starting a Live Activity is permitted, and recording proceeds.
/// The foreground hop only happens on that specific failure — when the headless
/// background start succeeds, recording stays fully headless.
@available(iOS 18, *)
private func startRecordingContinuingInForegroundIfNeeded(
    from intent: some ForegroundContinuableIntent
) async throws {
    let service = await TranscriptionRecordingService.shared
    do {
        try await service.startRecording()
    } catch iOSTranscriptionError.liveActivityUnavailable {
        try await intent.requestToContinueInForeground {
            try await TranscriptionRecordingService.shared.startRecording()
        }
    }
}

/// Idempotent start intent for users who wire their Action Button / Shortcut
/// to a one-shot start (and a separate one to stop). If a recording is already
/// in progress this intent leaves it running and reports the state.
@available(iOS 18, *)
public struct StartTranscriptionIntent: AudioRecordingIntent, ForegroundContinuableIntent {
    public static var title: LocalizedStringResource = "Start Recording"
    public static var description = IntentDescription(
        "Start a fresh transcription. No-op if already recording. Pair with Stop Recording to finish."
    )

    public static var openAppWhenRun: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = await TranscriptionRecordingService.shared
        let isRunning = await service.isRunning
        if isRunning {
            return .result(dialog: "Recording already in progress.")
        }
        try await startRecordingContinuingInForegroundIfNeeded(from: self)
        return .result(dialog: "Recording started. Run \"Stop Recording\" to finish.")
    }
}

/// Toggle intent for starting/stopping transcription via Action Button, Siri, or Shortcuts.
/// Conforms to AudioRecordingIntent so the system allows background audio recording
/// and shows the recording indicator. Requires iOS 18+.
@available(iOS 18, *)
public struct StartTranscriptionRecordingIntent: AudioRecordingIntent, ForegroundContinuableIntent {
    public static var title: LocalizedStringResource = "Toggle Recording"
    public static var description = IntentDescription(
        "Start or stop voice transcription. Result lands in the destination you chose in Settings."
    )

    public static var openAppWhenRun: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = await TranscriptionRecordingService.shared
        let isRunning = await service.isRunning
        let destination = await AppSettings.shared.hardwareTriggerDestination
        let canPostProcess = await AppSettings.shared.hasOpenRouterKey

        if isRunning {
            let result = await service.stopRecording(destination: destination)
            return .result(dialog: stopResultDialog(
                for: result,
                destination: destination,
                canPostProcess: canPostProcess
            ))
        } else {
            try await startRecordingContinuingInForegroundIfNeeded(from: self)
            return .result(dialog: "Recording started. Press again to stop.")
        }
    }
}

/// Intent to stop an active recording from a Live Activity button or a dedicated
/// Shortcut paired with `StartTranscriptionIntent`.
@available(iOS 18, *)
public struct StopTranscriptionRecordingIntent: AppIntent {
    public static var title: LocalizedStringResource = "Stop Recording"
    public static var description = IntentDescription(
        "Stops the current transcription and routes the result to the destination you chose in Settings."
    )

    public static var openAppWhenRun: Bool = false

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = await TranscriptionRecordingService.shared
        let isRunning = await service.isRunning

        guard isRunning else {
            return .result(dialog: "No active recording.")
        }

        let destination = await AppSettings.shared.hardwareTriggerDestination
        let canPostProcess = await AppSettings.shared.hasOpenRouterKey
        let result = await service.stopRecording(destination: destination)
        return .result(dialog: stopResultDialog(
            for: result,
            destination: destination,
            canPostProcess: canPostProcess
        ))
    }
}

/// Control Center toggle intent for one-tap start/stop of transcription.
///
/// This lives in SpeakiOSLib (not the widget extension) so it can adopt
/// `ForegroundContinuableIntent` and reuse the same background-recovery path as
/// the Action Button. Control Center runs this intent in the app's *background*
/// process, where ActivityKit refuses to start the mandatory Live Activity, so a
/// plain `startRecording()` would fail with `liveActivityUnavailable`. Conforming
/// to `AudioRecordingIntent` requests the background-audio grant, and the
/// foreground fallback brings the app forward when the headless start is refused.
///
/// The widget extension only ever uses this as a `SetValueIntent` (via
/// `ControlWidgetToggle`), so it never references `ForegroundContinuableIntent`
/// itself — that protocol is unavailable to app extensions, but merely using a
/// type that conforms to it is allowed.
@available(iOS 18, *)
public struct ToggleTranscriptionControlIntent: SetValueIntent, AudioRecordingIntent, ForegroundContinuableIntent {
    public static var title: LocalizedStringResource = "Toggle Transcription"

    @Parameter(title: "Recording")
    public var value: Bool

    public init() {}

    public func perform() async throws -> some IntentResult {
        let service = await TranscriptionRecordingService.shared
        if value {
            try await startRecordingContinuingInForegroundIfNeeded(from: self)
        } else {
            await service.stopRecording(destination: AppSettings.shared.hardwareTriggerDestination)
        }
        return .result()
    }
}

// MARK: - Copy Intents

/// App Intent to copy the last transcribed sentence to clipboard.
/// Can be triggered from Live Activity, Shortcuts, or Siri.
struct CopyLastSentenceIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy Last Sentence"
    static var description = IntentDescription("Copies the most recent transcribed sentence to the clipboard")

    // Make this available from Live Activity
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        // Get the last sentence from UserDefaults (shared between app and extension)
        let defaults = UserDefaults(suiteName: SharedTranscriptionState.appGroupIdentifier)
        let lastSentence = defaults?.string(forKey: "lastTranscribedSentence") ?? ""

        guard !lastSentence.isEmpty else {
            return .result(value: "No recent transcription to copy")
        }

        await MainActor.run {
            UIPasteboard.general.string = lastSentence
        }

        return .result(value: "Copied: \(lastSentence.prefix(50))...")
    }
}

/// App Intent to copy the full transcript to clipboard.
struct CopyFullTranscriptIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy Full Transcript"
    static var description = IntentDescription("Copies the entire transcription to the clipboard")

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult {
        let defaults = UserDefaults(suiteName: SharedTranscriptionState.appGroupIdentifier)
        let fullText = defaults?.string(forKey: "currentTranscriptText") ?? ""

        guard !fullText.isEmpty else {
            return .result(value: "No transcription to copy")
        }

        await MainActor.run {
            UIPasteboard.general.string = fullText
        }

        let wordCount = fullText.split(separator: " ").count
        return .result(value: "Copied \(wordCount) words")
    }
}

/// App Shortcuts provider exposing transcription actions (iOS 18+, includes recording).
@available(iOS 18, *)
struct TranscriptionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTranscriptionRecordingIntent(),
            phrases: [
                "Toggle recording with \(.applicationName)",
                "Transcribe with \(.applicationName)",
                "Record with \(.applicationName)"
            ],
            shortTitle: "Toggle Recording",
            systemImageName: "mic.fill"
        )

        AppShortcut(
            intent: StartTranscriptionIntent(),
            phrases: [
                "Start recording with \(.applicationName)",
                "Start transcription with \(.applicationName)"
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.badge.plus"
        )

        AppShortcut(
            intent: StopTranscriptionRecordingIntent(),
            phrases: [
                "Stop recording with \(.applicationName)",
                "Stop transcription with \(.applicationName)"
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.fill"
        )

        AppShortcut(
            intent: CopyLastSentenceIntent(),
            phrases: [
                "Copy last sentence from \(.applicationName)",
                "Copy recent transcription from \(.applicationName)"
            ],
            shortTitle: "Copy Last Sentence",
            systemImageName: "doc.on.doc"
        )

        AppShortcut(
            intent: CopyFullTranscriptIntent(),
            phrases: [
                "Copy full transcript from \(.applicationName)",
                "Copy all transcription from \(.applicationName)"
            ],
            shortTitle: "Copy Full Transcript",
            systemImageName: "doc.on.doc.fill"
        )
    }
}

// MARK: - Shared State Manager

/// Manages state shared between main app and extensions via App Group.
public final class SharedTranscriptionState {
    public static let shared = SharedTranscriptionState()
    public static let appGroupIdentifier = "group.com.justspeaktoit.ios"

    private let defaults: UserDefaults?

    private init() {
        defaults = UserDefaults(suiteName: Self.appGroupIdentifier)
    }

    /// Updates the current transcript text (for copy action)
    public func updateTranscript(_ text: String) {
        defaults?.set(text, forKey: "currentTranscriptText")

        // Extract and store last sentence
        if let lastSentence = extractLastSentence(from: text) {
            defaults?.set(lastSentence, forKey: "lastTranscribedSentence")
        }
    }

    /// Clears all shared state
    public func clear() {
        defaults?.removeObject(forKey: "currentTranscriptText")
        defaults?.removeObject(forKey: "lastTranscribedSentence")
    }

    // MARK: - Recording State

    /// Whether a headless recording session is currently active.
    public var isRecording: Bool {
        get { defaults?.bool(forKey: "isRecording") ?? false }
        set { defaults?.set(newValue, forKey: "isRecording") }
    }

    /// Start time of the current recording session.
    public var recordingStartTime: Date? {
        get { defaults?.object(forKey: "recordingStartTime") as? Date }
        set {
            if let date = newValue {
                defaults?.set(date, forKey: "recordingStartTime")
            } else {
                defaults?.removeObject(forKey: "recordingStartTime")
            }
        }
    }

    /// The most recently completed transcript (for clipboard result).
    public var lastCompletedTranscript: String? {
        get { defaults?.string(forKey: "lastCompletedTranscript") }
        set {
            if let text = newValue {
                defaults?.set(text, forKey: "lastCompletedTranscript")
                // Stamp completion time and flag it unseen so the app can surface
                // the latest background (Action Button / Siri / Shortcuts) session
                // and badge History on next foreground. Only background sessions
                // set this key, so in-app recordings don't raise the marker.
                defaults?.set(Date(), forKey: "lastCompletedAt")
                defaults?.set(true, forKey: "hasUnseenBackgroundTranscript")
            } else {
                defaults?.removeObject(forKey: "lastCompletedTranscript")
                defaults?.removeObject(forKey: "lastCompletedAt")
                defaults?.set(false, forKey: "hasUnseenBackgroundTranscript")
            }
        }
    }

    /// When `lastCompletedTranscript` was last written by a background session.
    public var lastCompletedAt: Date? {
        defaults?.object(forKey: "lastCompletedAt") as? Date
    }

    /// Whether a background session finished a transcript the user hasn't been
    /// shown in-app yet. Drives the History badge and the "surface as current
    /// view" behaviour.
    public var hasUnseenBackgroundTranscript: Bool {
        get { defaults?.bool(forKey: "hasUnseenBackgroundTranscript") ?? false }
        set { defaults?.set(newValue, forKey: "hasUnseenBackgroundTranscript") }
    }

    /// Marks the latest background transcript as seen (clears the History badge).
    public func markBackgroundTranscriptSeen() {
        hasUnseenBackgroundTranscript = false
    }

    /// Clears recording-specific state when a session ends.
    public func clearRecordingState() {
        isRecording = false
        recordingStartTime = nil
    }

    private func extractLastSentence(from text: String) -> String? {
        // Split by sentence-ending punctuation
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return sentences.last
    }
}
#endif
