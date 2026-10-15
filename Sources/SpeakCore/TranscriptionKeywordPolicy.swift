import Foundation

/// Reconciles the current and legacy preference mirrors without undoing a
/// deliberate clear or discarding the competing edit.
public enum TranscriptionKeywordPolicy {
    /// Recognition terms only; provider-specific bounds are applied at the wire boundary.
    public static func words(from value: String) -> [String] {
        var seen = Set<String>()
        return value.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    public static func bounded(_ words: [String], count: Int, length: Int) -> [String] {
        var seen = Set<String>()
        return Array(words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= length && seen.insert($0.lowercased()).inserted }
            .prefix(count))
    }

    /// A glossary, never a post-processing or style instruction.
    public static func prompt(_ words: [String], maximumCharacters: Int = 224) -> String? {
        var result = ""
        let usable = words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.utf8.count <= maximumCharacters }
        for word in bounded(usable, count: 100, length: maximumCharacters) {
            let next = result.isEmpty ? word : result + ", " + word
            guard next.utf8.count <= maximumCharacters else { break }
            result = next
        }
        return result.isEmpty ? nil : result
    }

    /// Nova-3/Flux use plain keyterms; the older model families use keywords.
    public static func deepgramQuery(model: String, words: [String]) -> [URLQueryItem] {
        let name: String
        if model.hasPrefix("nova-3") || model.hasPrefix("flux-") {
            name = "keyterm"
        } else if model.hasPrefix("nova-2") || ["nova", "enhanced", "base"].contains(model) {
            name = "keywords"
        } else {
            return []
        }
        // A byte ceiling is deliberately conservative without a provider tokenizer.
        // UTF-8 bytes plus separators cannot exceed the documented 500-token budget.
        return budgeted(words, maximumBytes: 500).map { URLQueryItem(name: name, value: $0) }
    }

    public static func budgeted(_ words: [String], maximumBytes: Int) -> [String] {
        var remaining = maximumBytes
        return bounded(words, count: 100, length: 100).filter { word in
            let cost = word.utf8.count + 1
            guard cost <= remaining else { return false }
            remaining -= cost
            return true
        }
    }

    public static func reconcile(
        canonical: String, legacy: String, lastReconciled: String?
    ) -> (active: String, recovered: String?) {
        if canonical == legacy { return (canonical, nil) }
        let canonicalIsEmpty = canonical.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let legacyIsEmpty = legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let lastReconciled {
            if canonical == lastReconciled { return (legacy, nil) }
            if legacy == lastReconciled { return (canonical, nil) }
            if canonicalIsEmpty || legacyIsEmpty {
                let recovered = canonicalIsEmpty ? legacy : canonical
                return ("", recovered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : recovered)
            }
        }
        if canonicalIsEmpty { return (legacy, nil) }
        if legacyIsEmpty { return (canonical, nil) }
        var seen: Set<String> = []
        let merged = (canonical + "," + legacy).components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ", ")
        return (merged, nil)
    }
}
