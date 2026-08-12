import Foundation

/// The keyboard's dictation language plus the quick-switch ring shown as a
/// chip in the keyboard. Shared through the App Group so the containing app's
/// language preference reaches the extension and keyboard-side switches
/// persist across appearances.
public struct KeyboardLanguageSelection: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maxQuickOptions = 4

    public let schemaVersion: Int
    public let selectedIdentifier: String
    /// Ordered, deduplicated ring of identifiers; always contains the
    /// selection at the front.
    public let quickIdentifiers: [String]

    public init(
        schemaVersion: Int = Self.schemaVersion,
        selectedIdentifier: String,
        quickIdentifiers: [String]
    ) {
        self.schemaVersion = schemaVersion
        let selected = TranscriptionLanguageCatalog.normalizedIdentifier(selectedIdentifier)
        self.selectedIdentifier = selected
        var seen = Set<String>()
        let merged = ([selected] + quickIdentifiers.map(TranscriptionLanguageCatalog.normalizedIdentifier))
            .filter { seen.insert($0).inserted }
        self.quickIdentifiers = Array(merged.prefix(Self.maxQuickOptions))
    }

    public static let automaticOnly = KeyboardLanguageSelection(
        selectedIdentifier: TranscriptionLanguageCatalog.automaticIdentifier,
        quickIdentifiers: []
    )

    /// The quick language after the current selection, or `nil` when there is
    /// nothing to switch to.
    public var nextQuickIdentifier: String? {
        guard quickIdentifiers.count > 1,
              let index = quickIdentifiers.firstIndex(of: selectedIdentifier) else {
            return nil
        }
        return quickIdentifiers[(index + 1) % quickIdentifiers.count]
    }

    /// Selects `identifier`, keeping the ring's order so repeated chip taps
    /// cycle predictably.
    public func selecting(_ identifier: String) -> KeyboardLanguageSelection {
        let normalized = TranscriptionLanguageCatalog.normalizedIdentifier(identifier)
        guard quickIdentifiers.contains(normalized) else {
            return KeyboardLanguageSelection(
                selectedIdentifier: normalized,
                quickIdentifiers: quickIdentifiers
            )
        }
        return KeyboardLanguageSelection(
            schemaVersion: schemaVersion,
            selectedIdentifier: normalized,
            quickIdentifiers: reordered(startingWith: normalized)
        )
    }

    /// Compact label for the keyboard chip, e.g. "Auto" or "EN-GB".
    public static func chipLabel(for identifier: String) -> String {
        let normalized = TranscriptionLanguageCatalog.normalizedIdentifier(identifier)
        guard normalized != TranscriptionLanguageCatalog.automaticIdentifier else { return "Auto" }
        return normalized.replacingOccurrences(of: "_", with: "-").uppercased()
    }

    private func reordered(startingWith identifier: String) -> [String] {
        guard let index = quickIdentifiers.firstIndex(of: identifier) else { return quickIdentifiers }
        return Array(quickIdentifiers[index...] + quickIdentifiers[..<index])
    }
}

/// App Group-backed storage for ``KeyboardLanguageSelection``. Language
/// identifiers are the only content; no transcript or audio data enters this
/// store.
public final class KeyboardDictationPreferencesStore {
    public static let shared = KeyboardDictationPreferencesStore()

    private static let selectionKey = "keyboardDictation.language.v1"

    private let defaults: UserDefaults?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    public convenience init() {
        self.init(defaults: UserDefaults(suiteName: KeyboardHandoffStore.appGroupIdentifier))
    }

    /// Injectable for deterministic tests. Passing `nil` models a missing or
    /// inaccessible App Group.
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    public func selection() -> KeyboardLanguageSelection {
        lock.withLock {
            readUnlocked() ?? .automaticOnly
        }
    }

    /// Mirrors the containing app's language preference into the quick ring
    /// without discarding languages already chosen from the keyboard.
    @discardableResult
    public func mirrorAppPreference(selectedIdentifier: String) -> KeyboardLanguageSelection {
        lock.withLock {
            let current = readUnlocked() ?? .automaticOnly
            let updated = KeyboardLanguageSelection(
                selectedIdentifier: selectedIdentifier,
                quickIdentifiers: current.quickIdentifiers
            )
            writeUnlocked(updated)
            return updated
        }
    }

    /// Records a keyboard-side quick switch.
    @discardableResult
    public func select(_ identifier: String) -> KeyboardLanguageSelection {
        lock.withLock {
            let current = readUnlocked() ?? .automaticOnly
            let updated = current.selecting(identifier)
            writeUnlocked(updated)
            return updated
        }
    }

    private func readUnlocked() -> KeyboardLanguageSelection? {
        guard let data = defaults?.data(forKey: Self.selectionKey),
              let selection = try? decoder.decode(KeyboardLanguageSelection.self, from: data),
              selection.schemaVersion == KeyboardLanguageSelection.schemaVersion else {
            return nil
        }
        return selection
    }

    private func writeUnlocked(_ selection: KeyboardLanguageSelection) {
        guard let defaults, let data = try? encoder.encode(selection) else { return }
        defaults.set(data, forKey: Self.selectionKey)
    }
}
