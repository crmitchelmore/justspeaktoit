import Foundation

/// Recognition hints only: legacy dictionary values are not TTS replacements.
public enum AssemblyAIPronunciationKeyterms {
    public static func parse(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isValid)
    }

    public static func seeds(modern: [String], legacy: [String]) -> [String] {
        var seen = Set<String>()
        return (modern + legacy.sorted())
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isValid($0) && seen.insert(canonical($0)).inserted }
    }

    public static func merged(current: [String], seeds: [String], ignored: [String]) -> [String] {
        let excluded = Set(ignored.map(canonical))
        var seen = Set<String>()
        var result: [String] = []
        for term in current where seen.insert(canonical(term)).inserted {
            result.append(term)
        }
        for term in seeds where !excluded.contains(canonical(term)) && seen.insert(canonical(term)).inserted {
            result.append(term)
        }
        return Array(result.prefix(100))
    }

    public static func ignored(selected: String, seeds: [String], stored: [String]) -> [String] {
        let selected = Set(parse(selected).map(canonical))
        var result = Set(stored.map(canonical))
        for term in seeds {
            let key = canonical(term)
            if selected.contains(key) {
                result.remove(key)
            } else {
                result.insert(key)
            }
        }
        return result.sorted()
    }

    private static func canonical(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isValid(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains(",") && trimmed.count <= 50
    }
}
