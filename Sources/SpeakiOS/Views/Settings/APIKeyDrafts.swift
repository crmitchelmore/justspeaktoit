#if os(iOS)
import Foundation

/// The keys typed on the API Keys screen, keyed by entry id.
///
/// Every field reads and writes here, so whether Save has anything to save
/// covers each editable key, including a provider added later.
struct APIKeyDrafts: Equatable {
    private var values: [String: String] = [:]

    subscript(id: String) -> String {
        get { self.values[id] ?? "" }
        set { self.values[id] = newValue }
    }

    var hasUnsavedKey: Bool {
        self.values.values.contains { !$0.isEmpty }
    }

    /// The non-empty drafts at the moment Save is pressed.
    func submission() -> [String: String] {
        self.values.filter { !$0.value.isEmpty }
    }

    /// Clears a saved draft, unless the user has edited it since submitting.
    mutating func clear(_ id: String, ifStill submitted: String) {
        guard self.values[id] == submitted else { return }
        self.values[id] = nil
    }
}
#endif
