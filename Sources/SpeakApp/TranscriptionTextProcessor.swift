import AppKit
import Foundation

/// Processes transcription text to expand voice commands like "copy pasta" into actual content.
/// This runs after raw transcription but before personal lexicon and post-processing.
@MainActor
final class TranscriptionTextProcessor {
    private let appSettings: AppSettings

    /// Built-in voice commands and their variations
    private static let clipboardTriggers: Set<String> = [
        "copy pasta",
        "copypasta",
        "copy paste",
        "copypaste",
        "paste clipboard",
        "pasteclipboard",
        "clipboard paste",
        "clipboardpaste",
        "insert clipboard",
        "insertclipboard"
    ]
    
    /// Maximum recursion depth for clipboard expansion to prevent DoS attacks
    /// when clipboard content contains trigger phrases. Set to 10 to allow
    /// reasonable legitimate nested triggers while preventing infinite loops.
    private static let maxClipboardExpansionDepth = 10

    init(appSettings: AppSettings) {
        self.appSettings = appSettings
    }

    /// Process transcription text, expanding any voice commands found.
    /// - Parameter text: Raw transcription text
    /// - Returns: Processed text with voice commands expanded
    func process(_ text: String) -> String {
        guard appSettings.voiceCommandsEnabled else { return text }

        var result = text

        // Process clipboard insertion commands
        result = expandClipboardCommands(in: result)

        return result
    }

    /// Expand clipboard insertion triggers ("copy pasta" etc.) with actual clipboard content
    private func expandClipboardCommands(in text: String) -> String {
        return expandClipboardCommands(in: text, depth: 0)
    }

    /// Expand clipboard insertion triggers with depth limit to prevent infinite recursion
    private func expandClipboardCommands(in text: String, depth: Int) -> String {
        guard depth < Self.maxClipboardExpansionDepth else { return text }

        let clipboardContent = NSPasteboard.general.string(forType: .string) ?? ""
        guard !clipboardContent.isEmpty else { return text }

        var result = text
        let lowercased = text.lowercased()

        // Check custom triggers first (from settings)
        let customTriggers = appSettings.clipboardInsertionTriggers
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        let allTriggers = Self.clipboardTriggers.union(Set(customTriggers))

        for trigger in allTriggers {
            if let range = lowercased.range(of: trigger) {
                let originalRange = Range(
                    uncheckedBounds: (
                        result.index(result.startIndex, offsetBy: lowercased.distance(from: lowercased.startIndex, to: range.lowerBound)),
                        result.index(result.startIndex, offsetBy: lowercased.distance(from: lowercased.startIndex, to: range.upperBound))
                    )
                )
                result.replaceSubrange(originalRange, with: clipboardContent)
                // Re-process in case there are multiple triggers (with updated positions)
                return expandClipboardCommands(in: result, depth: depth + 1)
            }
        }

        return result
    }
}
