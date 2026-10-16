import Foundation

/// Reconciles the current and legacy preference mirrors without undoing a
/// deliberate clear or discarding the competing edit.
public enum TranscriptionKeywordPolicy {
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
