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
    private static let clipboardTriggers: [String] = [
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

        guard let range = Self.triggerRange(in: text, triggers: resolvedTriggers()) else { return text }

        var result = text
        result.replaceSubrange(range, with: clipboardContent)
        // Re-process in case there are multiple triggers (with updated positions).
        return expandClipboardCommands(in: result, depth: depth + 1)
    }

    /// The trigger phrases to match, in a stable order.
    ///
    /// Custom phrases come first and duplicates collapse case-insensitively, so a
    /// custom phrase that repeats a built-in is one trigger, not two.
    private func resolvedTriggers() -> [String] {
        let customTriggers = configuration.customTriggers()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        return (customTriggers + Self.clipboardTriggers)
            .filter { seen.insert($0).inserted }
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count
            }
    }

    /// The range to replace: the earliest trigger in the text, and the longest
    /// trigger of the several that can start there.
    ///
    /// Set iteration order used to decide this, so "paste clipboard" expanded to
    /// either the clipboard content or `<clipboard content> clipboard` across
    /// launches when a custom "paste" trigger was also configured (issue #687).
    private static func triggerRange(in text: String, triggers: [String]) -> Range<String.Index>? {
        var best: Range<String.Index>?
        for trigger in triggers {
            guard let range = earliestWholePhraseRange(of: trigger, in: text) else { continue }
            guard let current = best else {
                best = range
                continue
            }
            if range.lowerBound < current.lowerBound {
                best = range
            } else if range.lowerBound == current.lowerBound, range.upperBound > current.upperBound {
                best = range
            }
        }
        return best
    }

    /// The first case-insensitive match of `trigger` that is a whole phrase.
    ///
    /// Triggers never fire inside a longer word: "copypasta" must not expand in
    /// "copypastas".
    private static func earliestWholePhraseRange(
        of trigger: String,
        in text: String
    ) -> Range<String.Index>? {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
            let range = text.range(
                of: trigger,
                options: [.caseInsensitive],
                range: searchStart..<text.endIndex
            ) {
            if isWholePhrase(range, in: text) { return range }
            searchStart = text.index(after: range.lowerBound)
        }
        return nil
    }

    private static func isWholePhrase(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex,
            isWordCharacter(text[text.index(before: range.lowerBound)]) {
            return false
        }
        if range.upperBound < text.endIndex, isWordCharacter(text[range.upperBound]) {
            return false
        }
        return true
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
