#if os(iOS)
import AppIntents
import UIKit

// MARK: - Audio Recording Intent (Action Button / Shortcuts)

/// Toggle intent for starting/stopping transcription via Action Button, Siri, or Shortcuts.
/// Conforms to AudioRecordingIntent so the system allows background audio recording
/// and shows the recording indicator. Requires iOS 18+.
@available(iOS 18, *)
struct StartTranscriptionRecordingIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "Transcribe Voice"
    static var description = IntentDescription(
        "Start or stop voice transcription. The transcript is copied to your clipboard automatically."
    )

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = await TranscriptionRecordingService.shared
        let isRunning = await service.isRunning

        if isRunning {
            let result = await service.stopRecording()
            let wordCount = result.text.split(separator: " ").count
            if result.text.isEmpty {
                return .result(dialog: "Recording stopped. No speech detected.")
            }
            return .result(dialog: "Copied \(wordCount) words to clipboard.")
        } else {
            try await service.startRecording()
            return .result(dialog: "Recording started. Press again to stop and copy.")
        }
    }
}

/// Intent to stop an active recording from a Live Activity button.
@available(iOS 18, *)
struct StopTranscriptionRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Transcription"
    static var description = IntentDescription("Stops the current transcription and copies it to clipboard")

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = await TranscriptionRecordingService.shared
        let isRunning = await service.isRunning

        guard isRunning else {
            return .result(dialog: "No active recording.")
        }

        let result = await service.stopRecording()
        let wordCount = result.text.split(separator: " ").count
        if result.text.isEmpty {
            return .result(dialog: "Recording stopped. No speech detected.")
        }
        return .result(dialog: "Copied \(wordCount) words to clipboard.")
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
        let defaults = UserDefaults(suiteName: "group.com.speak.ios")
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
        let defaults = UserDefaults(suiteName: "group.com.speak.ios")
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
                "Record with \(.applicationName)",
                "Transcribe with \(.applicationName)",
                "Start recording with \(.applicationName)",
                "Start transcription with \(.applicationName)"
            ],
            shortTitle: "Transcribe Voice",
            systemImageName: "mic.fill"
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
    
    private let defaults: UserDefaults?
    private let groupIdentifier = "group.com.speak.ios"
    
    private init() {
        defaults = UserDefaults(suiteName: groupIdentifier)
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
            } else {
                defaults?.removeObject(forKey: "lastCompletedTranscript")
            }
        }
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
