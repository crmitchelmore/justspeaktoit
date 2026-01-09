#if os(iOS)
import AppIntents
import UIKit

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

/// App Shortcuts provider exposing transcription actions.
struct TranscriptionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
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
    
    private func extractLastSentence(from text: String) -> String? {
        // Split by sentence-ending punctuation
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        return sentences.last
    }
}
#endif
