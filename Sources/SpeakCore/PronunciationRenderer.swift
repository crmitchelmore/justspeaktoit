import Foundation

/// The pronunciation dictionary's text-replacement semantics, independent of
/// its persistence and UI.
///
/// `PronunciationManager` delegates here, and portable voice output applies an
/// immutable entry snapshot through the same code, so a dictionary is spoken
/// identically on every platform. Thread safe. Compiled expressions are cached
/// by options and pattern; `Retention` decides how long they are kept, never
/// how text is replaced.
final class PronunciationRenderer: @unchecked Sendable {
    enum Retention: Sendable {
        /// Every compiled expression is kept for the renderer's lifetime: the
        /// dictionary manager's established behaviour, whatever its size.
        case unbounded
        /// After each dictionary pass, only the expressions that dictionary can
        /// use are kept. A long-lived renderer that sees many request snapshots
        /// then holds one dictionary's expressions, all of them warm.
        case activeDictionary
    }

    private let retention: Retention
    private let lock = NSLock()
    // Cache compiled NSRegularExpression instances; key = "<options.rawValue>:<pattern>"
    private var regexCache: [String: NSRegularExpression] = [:]
    private var compilations = 0

    init(retention: Retention = .unbounded) {
        self.retention = retention
    }

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

        if case .activeDictionary = retention { retainExpressions(of: entries) }
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
            guard let regex = cachedRegex(pattern: Self.wordPattern(word), options: .caseInsensitive) else {
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
        guard let regex = cachedRegex(pattern: pattern, options: Self.regexOptions(caseSensitive: caseSensitive)) else {
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
    /// Expressions compiled so far; unchanged by warm passes.
    var compilationCount: Int { lock.withLock { compilations } }

    private func cachedRegex(pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression? {
        let key = Self.cacheKey(pattern: pattern, options: options)
        if let cached = lock.withLock({ regexCache[key] }) {
            return cached
        }
        // Compiled outside the lock; a concurrent duplicate is equivalent.
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        lock.withLock {
            compilations += 1
            regexCache[key] = regex
        }
        return regex
    }

    /// Keeps the expressions any pass over `entries` can use, including the
    /// SSML path's, and drops the rest.
    private func retainExpressions(of entries: [PronunciationEntry]) {
        let keys = Set(entries.compactMap(Self.cacheKey(for:)))
        lock.withLock {
            guard regexCache.keys.contains(where: { !keys.contains($0) }) else { return }
            regexCache = regexCache.filter { keys.contains($0.key) }
        }
    }

    /// The compiled expression an entry can use; `nil` for literal matching.
    private static func cacheKey(for entry: PronunciationEntry) -> String? {
        if entry.isRegex {
            return cacheKey(pattern: entry.word, options: regexOptions(caseSensitive: entry.caseSensitive))
        }
        return entry.caseSensitive ? nil : cacheKey(pattern: wordPattern(entry.word), options: .caseInsensitive)
    }

    private static func wordPattern(_ word: String) -> String {
        "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
    }

    private static func regexOptions(caseSensitive: Bool) -> NSRegularExpression.Options {
        var options: NSRegularExpression.Options = []
        if !caseSensitive {
            options.insert(.caseInsensitive)
        }
        return options
    }

    private static func cacheKey(pattern: String, options: NSRegularExpression.Options) -> String {
        "\(options.rawValue):\(pattern)"
    }
}
