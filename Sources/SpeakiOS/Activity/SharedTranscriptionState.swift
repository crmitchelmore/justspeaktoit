import Foundation
import SpeakCore

/// Manages state shared between main app and extensions via App Group.
public final class SharedTranscriptionState {
    public static let shared = SharedTranscriptionState()
    public static let appGroupIdentifier = KeyboardHandoffStore.appGroupIdentifier

    private let defaults: UserDefaults?
    private let reloadRecordingControl: (String) -> Void

    private convenience init() {
        // Verified centrally so a missing effective entitlement fails the same
        // way here as in every other App Group store: a logged fault and an
        // unavailable, no-op store.
        self.init(
            defaults: AppGroupAvailability.verifiedDefaults(),
            reloadRecordingControl: CaptureSurfaceRefresher.recordingStateChanged(controlKind:)
        )
        #if DEBUG && targetEnvironment(simulator)
        if let value = ProcessInfo.processInfo.environment["JUSTSPEAKTOIT_SIMULATOR_TRANSCRIPT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty {
            defaults?.set(value, forKey: "simulatorValidationTranscript")
        }
        #endif
    }

    /// Allows tests to isolate shared state from the real App Group.
    init(
        defaults: UserDefaults?,
        reloadRecordingControl: @escaping (String) -> Void = { _ in }
    ) {
        self.defaults = defaults
        self.reloadRecordingControl = reloadRecordingControl
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Deterministic transcript used only by Simulator UX validation. App Intent
    /// execution does not reliably inherit launchd environment variables, so the
    /// App Group value keeps the real Shortcut lifecycle testable across hosts.
    var simulatorValidationTranscript: String? {
        let environmentValue = ProcessInfo.processInfo.environment["JUSTSPEAKTOIT_SIMULATOR_TRANSCRIPT"]
        let value = environmentValue ?? defaults?.string(forKey: "simulatorValidationTranscript")
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue?.isEmpty == false ? trimmedValue : nil
    }
    #endif

    public var isAvailable: Bool {
        defaults != nil
    }

    /// The full transcript currently shared with extensions and App Intents.
    public var currentTranscriptText: String { defaults?.string(forKey: "currentTranscriptText") ?? "" }

    /// The most recent sentence shared with extensions and App Intents.
    public var lastTranscribedSentence: String { defaults?.string(forKey: "lastTranscribedSentence") ?? "" }

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

    /// Whether either recording owner has published an active session.
    public var isRecording: Bool {
        get { defaults?.bool(forKey: "isRecording") ?? false }
        set {
            guard let defaults, defaults.bool(forKey: "isRecording") != newValue else { return }
            defaults.set(newValue, forKey: "isRecording")
            // Publish before WidgetKit re-queries the provider. Both owners and
            // all recording cleanup paths use this boundary; transcript writes do not.
            reloadRecordingControl(CaptureSurfaceKind.transcriptionControl)
        }
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
        recordingStartTime = nil
        isRecording = false
    }

    private func extractLastSentence(from text: String) -> String? {
        // Split by sentence-ending punctuation
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return sentences.last
    }
}
