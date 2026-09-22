import Foundation

/// The pronunciation dictionary's text-replacement semantics, independent of
/// its persistence and UI.
///
/// `PronunciationManager` delegates here, and portable voice output applies an
/// immutable entry snapshot through the same code, so a dictionary is spoken
/// identically on every platform. Thread safe. Compiled expressions are cached
/// by options and pattern; the cache is bounded because a long-lived renderer
/// can outlive many edited dictionaries, and a full cache is simply rebuilt.
final class PronunciationRenderer: @unchecked Sendable {
    static let maximumCachedExpressions = 512

    private let lock = NSLock()
    // Cache compiled NSRegularExpression instances; key = "<options.rawValue>:<pattern>"
    private var regexCache: [String: NSRegularExpression] = [:]

    /// Applies every entry with a non-empty replacement, in entry order, each
    /// to the result of the previous one.
    func applyReplacements(to text: String, entries: [PronunciationEntry]) -> String {
        var result = text

        for entry in entries {
            if let replacement = entry.replacement, !replacement.isEmpty {
                if entry.isRegex {
                    result = applyRegexReplacement(
                        text: result,
                        pattern: entry.word,
                        replacement: replacement,
                        caseSensitive: entry.caseSensitive
                    )
                } else {
                    result = applySimpleReplacement(
                        text: result,
                        word: entry.word,
                        replacement: replacement,
                        caseSensitive: entry.caseSensitive
                    )
                }
            }
        }

        return result
    }

    /// A case-sensitive word replaces every literal occurrence. Otherwise the
    /// word matches case-insensitively between word boundaries, and
    /// `replacement` is a regular-expression template.
    func applySimpleReplacement(
        text: String,
        word: String,
        replacement: String,
        caseSensitive: Bool
    ) -> String {
        if caseSensitive {
            return text.replacingOccurrences(of: word, with: replacement)
        } else {
            // Case-insensitive replacement with word boundaries
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
            guard let regex = cachedRegex(pattern: pattern, options: .caseInsensitive) else {
                return text
            }

            let range = NSRange(text.startIndex..., in: text)
            return regex.stringByReplacingMatches(
                in: text,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }
    }

    /// An invalid pattern leaves the text unchanged.
    func applyRegexReplacement(
        text: String,
        pattern: String,
        replacement: String,
        caseSensitive: Bool
    ) -> String {
        var options: NSRegularExpression.Options = []
        if !caseSensitive {
            options.insert(.caseInsensitive)
        }

        guard let regex = cachedRegex(pattern: pattern, options: options) else {
            return text
        }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }

    var cachedExpressionCount: Int { lock.withLock { regexCache.count } }

    private func cachedRegex(pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression? {
        let key = "\(options.rawValue):\(pattern)"
        if let cached = lock.withLock({ regexCache[key] }) {
            return cached
        }
        // Compiled outside the lock; a concurrent duplicate is equivalent.
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        lock.withLock {
            if regexCache.count >= Self.maximumCachedExpressions { regexCache.removeAll() }
            regexCache[key] = regex
        }
        return regex
    }
}
