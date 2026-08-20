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

/// A keyboard preference that is stored whole and rejected outright when a
/// future release changes its shape.
protocol KeyboardVersionedSelection: Codable {
    static var schemaVersion: Int { get }
    var schemaVersion: Int { get }
}

extension KeyboardLanguageSelection: KeyboardVersionedSelection {}
extension KeyboardProfileSelection: KeyboardVersionedSelection {}

private struct KeyboardStoredProfileIdentifier: KeyboardVersionedSelection {
    static let schemaVersion = 1
    let schemaVersion: Int
    let selectedIdentifier: String

    init(selectedIdentifier: String, schemaVersion: Int = Self.schemaVersion) {
        self.schemaVersion = schemaVersion
        self.selectedIdentifier = selectedIdentifier
    }
}

/// App Group-backed storage for the keyboard's quick-switch preferences:
/// ``KeyboardLanguageSelection`` and ``KeyboardProfileSelection``. The profile
/// projection contains non-secret model/language/route metadata only; no
/// transcript, audio, credential, surrounding text, or prompt enters this store.
public final class KeyboardDictationPreferencesStore {
    public static let shared = KeyboardDictationPreferencesStore()

    private static let selectionKey = "keyboardDictation.language.v1"
    private static let profileCatalogueKey = "keyboardDictation.profileCatalogue.v2"
    private static let profileSelectionKey = "keyboardDictation.profileSelection.v1"

    private let defaults: UserDefaults?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    public convenience init() {
        self.init(defaults: AppGroupAvailability.verifiedDefaults())
    }

    /// Injectable for deterministic tests. Passing `nil` models a missing or
    /// inaccessible App Group.
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    public var isAvailable: Bool {
        defaults != nil
    }

    // MARK: - Dictation profile

    public func profileSelection() -> KeyboardProfileSelection {
        lock.withLock {
            profileSelectionUnlocked()
        }
    }

    /// Publishes one coherent app-owned capability catalogue. A keyboard-side
    /// selection survives catalogue refreshes while its identifier remains
    /// available; deleted entries fall back visibly to the app default.
    @discardableResult
    public func publishAppProfileSelection(
        configuration: KeyboardAppProfileConfiguration,
        now: Date = Date()
    ) -> KeyboardProfileSelection {
        lock.withLock {
            let current = readUnlocked(KeyboardProfileSelection.self, key: Self.profileCatalogueKey)
            let updated = KeyboardDictationProfileCatalog.selection(
                for: configuration,
                revision: (current?.catalogueRevision ?? 0) + 1,
                modifiedAt: now
            )
            writeUnlocked(updated, key: Self.profileCatalogueKey)
            let selected = readUnlocked(
                KeyboardStoredProfileIdentifier.self,
                key: Self.profileSelectionKey
            )?.selectedIdentifier
            return updated.selecting(selected ?? updated.defaultIdentifier)
        }
    }

    /// Records a keyboard-side quick switch.
    @discardableResult
    public func selectProfile(_ identifier: String?) -> KeyboardProfileSelection {
        lock.withLock {
            let current = profileSelectionUnlocked()
            let updated = current.selecting(identifier)
            writeUnlocked(
                KeyboardStoredProfileIdentifier(selectedIdentifier: updated.selectedIdentifier),
                key: Self.profileSelectionKey
            )
            return updated
        }
    }

    // MARK: - Spoken language

    public func selection() -> KeyboardLanguageSelection {
        lock.withLock {
            readUnlocked(KeyboardLanguageSelection.self, key: Self.selectionKey) ?? .automaticOnly
        }
    }

    /// Mirrors the containing app's language preference into the quick ring
    /// without discarding languages already chosen from the keyboard.
    @discardableResult
    public func mirrorAppPreference(selectedIdentifier: String) -> KeyboardLanguageSelection {
        lock.withLock {
            let current = readUnlocked(KeyboardLanguageSelection.self, key: Self.selectionKey) ?? .automaticOnly
            let updated = KeyboardLanguageSelection(
                selectedIdentifier: selectedIdentifier,
                quickIdentifiers: current.quickIdentifiers
            )
            writeUnlocked(updated, key: Self.selectionKey)
            return updated
        }
    }

    /// Records a keyboard-side quick switch.
    @discardableResult
    public func select(_ identifier: String) -> KeyboardLanguageSelection {
        lock.withLock {
            let current = readUnlocked(KeyboardLanguageSelection.self, key: Self.selectionKey) ?? .automaticOnly
            let updated = current.selecting(identifier)
            writeUnlocked(updated, key: Self.selectionKey)
            return updated
        }
    }

    // MARK: - Storage

    /// Values written by a future schema version are ignored rather than
    /// migrated, so an older keyboard falls back to its safe default.
    private func readUnlocked<Value: KeyboardVersionedSelection>(
        _ type: Value.Type,
        key: String
    ) -> Value? {
        guard let data = defaults?.data(forKey: key),
              let value = try? decoder.decode(Value.self, from: data),
              value.schemaVersion == Value.schemaVersion else {
            return nil
        }
        return value
    }

    private func writeUnlocked<Value: KeyboardVersionedSelection>(_ value: Value, key: String) {
        guard let defaults, let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
        defaults.synchronize()
    }

    private func profileSelectionUnlocked() -> KeyboardProfileSelection {
        let catalogue = readUnlocked(KeyboardProfileSelection.self, key: Self.profileCatalogueKey) ?? .directOnly
        let selected = readUnlocked(
            KeyboardStoredProfileIdentifier.self,
            key: Self.profileSelectionKey
        )?.selectedIdentifier
        return catalogue.selecting(selected ?? catalogue.defaultIdentifier)
    }
}
