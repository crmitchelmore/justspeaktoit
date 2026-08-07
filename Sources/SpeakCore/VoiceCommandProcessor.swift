import Foundation

/// Platform-neutral core of transcription voice-command expansion
/// (e.g. "copy pasta" → clipboard contents).
/// Platform wrappers supply the clipboard contents and settings via closures,
/// keeping this logic shared between macOS and iOS.
@MainActor
public final class VoiceCommandProcessor {
    /// Platform/settings hooks for the processor.
    public struct Configuration {
        /// Whether voice-command expansion is enabled.
        public var isEnabled: () -> Bool
        /// Comma-separated custom trigger phrases configured by the user.
        public var customTriggers: () -> String
        /// Current plain-text clipboard contents, if any.
        public var clipboardText: () -> String?

        public init(
            isEnabled: @escaping () -> Bool,
            customTriggers: @escaping () -> String,
            clipboardText: @escaping () -> String?
        ) {
            self.isEnabled = isEnabled
            self.customTriggers = customTriggers
            self.clipboardText = clipboardText
        }
    }

    private let configuration: Configuration

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

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Process transcription text, expanding any voice commands found.
    /// - Parameter text: Raw transcription text
    /// - Returns: Processed text with voice commands expanded
    public func process(_ text: String) -> String {
        guard configuration.isEnabled() else { return text }

        var result = text

        // Process clipboard insertion commands
        result = expandClipboardCommands(in: result)

        return result
    }

    /// Expand clipboard insertion triggers ("copy pasta" etc.) with actual clipboard content
    private func expandClipboardCommands(in text: String) -> String {
        expandClipboardCommands(in: text, depth: 0)
    }

    /// Expand clipboard insertion triggers with depth limit to prevent infinite recursion
    private func expandClipboardCommands(in text: String, depth: Int) -> String {
        guard depth < Self.maxClipboardExpansionDepth else { return text }

        let clipboardContent = configuration.clipboardText() ?? ""
        guard !clipboardContent.isEmpty else { return text }

        var result = text
        let lowercased = text.lowercased()

        // Check custom triggers first (from settings)
        let customTriggers = configuration.customTriggers()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        let allTriggers = Self.clipboardTriggers.union(Set(customTriggers))

        for trigger in allTriggers {
            if let range = lowercased.range(of: trigger) {
                let lowerOffset = lowercased.distance(from: lowercased.startIndex, to: range.lowerBound)
                let upperOffset = lowercased.distance(from: lowercased.startIndex, to: range.upperBound)
                let originalRange = Range(
                    uncheckedBounds: (
                        result.index(result.startIndex, offsetBy: lowerOffset),
                        result.index(result.startIndex, offsetBy: upperOffset)
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
