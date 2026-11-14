import Foundation

/// One word change the keyboard saw the user make to a transcript it inserted.
public struct KeyboardCorrectionObservation: Codable, Equatable, Identifiable {
    public let id: UUID
    public let type: WordChange.ChangeType
    public let original: String
    public let corrected: String
    public let observedAt: Date

    public init(id: UUID = UUID(), change: WordChange, observedAt: Date) {
        self.id = id
        self.type = change.type
        self.original = change.original
        self.corrected = change.corrected
        self.observedAt = observedAt
    }

    public var change: WordChange {
        WordChange(type: type, original: original, corrected: corrected)
    }
}

/// App Group inbox for corrections the keyboard learns (F48, #1651). The
/// keyboard extension diffs the edited transcript in its own process and posts
/// only the changed words; the containing app owns the candidates and rules
/// and records each observation through the shared `AutoCorrectionDomain`.
///
/// One writing process per key, as in `KeyboardDeliveryStore`:
///
/// | Key               | Writer             | Contents                          |
/// |-------------------|--------------------|-----------------------------------|
/// | `enabled.v1`      | containing app     | whether learning is on            |
/// | `observations.v1` | keyboard extension | recent word changes, oldest first |
/// | `processed.v1`    | containing app     | observation IDs already recorded  |
///
/// No surrounding text is ever written here: an observation is the word or
/// words that changed and nothing else.
public final class KeyboardCorrectionStore: @unchecked Sendable {
    public static let shared = KeyboardCorrectionStore()

    /// The most observations the inbox keeps before dropping the oldest.
    public static let capacity = 100

    private static let enabledKey = "keyboardCorrections.enabled.v1"
    private static let observationsKey = "keyboardCorrections.observations.v1"
    private static let processedKey = "keyboardCorrections.processed.v1"

    private let defaults: UserDefaults?
    private let lock = NSLock()

    public convenience init() {
        self.init(defaults: AppGroupAvailability.verifiedDefaults())
    }

    /// Injectable for tests. `nil` models a missing App Group (no Full Access).
    public init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    public var isAvailable: Bool { defaults != nil }

    // MARK: - Containing app

    /// Whether the keyboard should watch for edits; mirrors the app setting.
    /// Always `false` without the App Group, where nothing could be posted.
    public var isLearningEnabled: Bool {
        lock.withLock { learningEnabledUnlocked() }
    }

    public func setLearningEnabled(_ enabled: Bool) {
        lock.withLock {
            guard let defaults, defaults.object(forKey: Self.enabledKey) as? Bool != enabled else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
        }
    }

    /// Observations the app has not recorded yet, oldest first.
    public func pendingObservations() -> [KeyboardCorrectionObservation] {
        lock.withLock {
            let processed = Set(processedUnlocked())
            return observationsUnlocked().filter { !processed.contains($0.id) }
        }
    }

    /// Marks observations as recorded, so the app never counts one twice and
    /// the keyboard can drop them from the inbox.
    public func markProcessed(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        lock.withLock {
            guard let defaults else { return }
            // An ID the inbox no longer holds can never come back, so only
            // IDs still in it need remembering.
            let live = Set(observationsUnlocked().map(\.id))
            var processed = processedUnlocked().filter { live.contains($0) }
            for id in ids where !processed.contains(id) {
                processed.append(id)
            }
            let strings = processed.suffix(Self.capacity * 2).map(\.uuidString)
            defaults.set(Array(strings), forKey: Self.processedKey)
        }
    }

    // MARK: - Keyboard extension

    /// Posts changes the keyboard observed. Nothing is written while learning
    /// is off. Observations the app has recorded are dropped first.
    @discardableResult
    public func append(_ changes: [WordChange], observedAt: Date = Date()) -> [KeyboardCorrectionObservation] {
        guard !changes.isEmpty else { return [] }
        return lock.withLock {
            guard let defaults, learningEnabledUnlocked() else { return [] }
            let processed = Set(processedUnlocked())
            let added = changes.map { KeyboardCorrectionObservation(change: $0, observedAt: observedAt) }
            let kept = observationsUnlocked().filter { !processed.contains($0.id) } + added
            guard let data = try? JSONEncoder().encode(Array(kept.suffix(Self.capacity))) else { return [] }
            defaults.set(data, forKey: Self.observationsKey)
            return added
        }
    }

    // MARK: - Private

    private func learningEnabledUnlocked() -> Bool {
        guard let defaults else { return false }
        return defaults.object(forKey: Self.enabledKey) as? Bool ?? AutoCorrectionLearningPolicy.enabledByDefault
    }

    private func observationsUnlocked() -> [KeyboardCorrectionObservation] {
        guard let data = defaults?.data(forKey: Self.observationsKey),
              let observations = try? JSONDecoder().decode([KeyboardCorrectionObservation].self, from: data)
        else { return [] }
        return observations
    }

    private func processedUnlocked() -> [UUID] {
        (defaults?.stringArray(forKey: Self.processedKey) ?? []).compactMap(UUID.init(uuidString:))
    }
}
