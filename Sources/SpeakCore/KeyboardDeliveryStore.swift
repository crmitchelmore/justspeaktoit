import Foundation

/// App Group store for keyboard *delivery*: the extension's open-target
/// advertisement, the app's pending transcript offer, the extension's claim on
/// it, and the app-owned delivery preferences (issues #1002, #1003, #1005).
///
/// It follows `KeyboardHandoffStore`'s discipline exactly — one writing process
/// per key, so no cross-process read-modify-write exists to race:
///
/// | Key             | Writer             | Contents                        |
/// |-----------------|--------------------|---------------------------------|
/// | `target.v1`     | keyboard extension | which document is open, briefly |
/// | `offer.v1`      | containing app     | one transcript awaiting delivery|
/// | `claim.v1`      | keyboard extension | the offer it took or dismissed  |
/// | `preferences.v1`| containing app     | hand-back / auto-insert choices |
///
/// No audio, credential, or surrounding text is ever written here. The whole
/// store lives behind Full Access: without it `AppGroupAvailability` yields no
/// defaults, every write is a no-op and every read is `nil`, so the keyboard
/// simply never advertises a target and never offers a chip, and hardware
/// triggers keep their existing clipboard behaviour.
public final class KeyboardDeliveryStore: @unchecked Sendable {
    public static let shared = KeyboardDeliveryStore()

    private static let targetKey = "keyboardDelivery.target.v1"
    private static let offerKey = "keyboardDelivery.offer.v1"
    private static let claimKey = "keyboardDelivery.claim.v1"
    private static let preferencesKey = "keyboardDelivery.preferences.v1"

    private let defaults: UserDefaults?
    private let announceStatusChange: @Sendable () -> Void
    private let lock = NSLock()

    public convenience init() {
        self.init(defaults: AppGroupAvailability.verifiedDefaults())
    }

    /// Injectable for deterministic tests. Passing `nil` models a missing or
    /// inaccessible App Group, which is what "no Full Access" looks like.
    public init(
        defaults: UserDefaults?,
        announceStatusChange: @escaping @Sendable () -> Void = KeyboardHandoffSignal.postStatusChanged
    ) {
        self.defaults = defaults
        self.announceStatusChange = announceStatusChange
    }

    public var isAvailable: Bool { defaults != nil }

    // MARK: - Target (extension-owned)

    /// Advertises the document the keyboard is currently on screen in, or
    /// refreshes an existing advertisement. Returns the record actually stored,
    /// or `nil` when the store is unavailable.
    ///
    /// Refreshing is throttled: an unchanged document is rewritten at most once
    /// per `KeyboardTargetRecord.refreshInterval`, so the keyboard's poll loop
    /// does not write to the App Group on every tick.
    @discardableResult
    public func publishTarget(
        documentIdentifier: UUID,
        isSecureField: Bool = false,
        now: Date = Date()
    ) -> KeyboardTargetRecord? {
        lock.withLock {
            guard let defaults else { return nil }
            if let current = readUnlocked(KeyboardTargetRecord.self, key: Self.targetKey),
               current.documentIdentifier == documentIdentifier,
               current.isSecureField == isSecureField,
               now.timeIntervalSince(current.updatedAt) < KeyboardTargetRecord.refreshInterval {
                return current
            }
            let record = KeyboardTargetRecord(
                documentIdentifier: documentIdentifier,
                updatedAt: now,
                expiresAt: now.addingTimeInterval(KeyboardTargetRecord.lifetime),
                isSecureField: isSecureField
            )
            writeUnlocked(record, key: Self.targetKey, to: defaults)
            return record
        }
    }

    /// Withdraws the advertisement on dismissal. The lifetime covers the case
    /// where this never runs.
    public func clearTarget() {
        lock.withLock {
            defaults?.removeObject(forKey: Self.targetKey)
            defaults?.synchronize()
        }
    }

    /// The keyboard's advertisement, or `nil` when it has lapsed.
    public func openTarget(now: Date = Date()) -> KeyboardTargetRecord? {
        lock.withLock {
            guard let record = readUnlocked(KeyboardTargetRecord.self, key: Self.targetKey),
                  record.isOpen(now: now) else {
                return nil
            }
            return record
        }
    }

    // MARK: - Offer (app-owned)

    /// Publishes one transcript for keyboard delivery, replacing any earlier
    /// one.
    ///
    /// The previous claim is deliberately **not** deleted here. A claim names
    /// the offer it settled (`KeyboardPickupClaim.offerID`), and every consumer
    /// compares that identifier against the current offer, so a stale claim
    /// already fails to suppress a replacement offer. Deleting it would open a
    /// cross-process race the single-writer discipline otherwise avoids: the
    /// keyboard can observe the new offer, insert it and write its claim in the
    /// window between the two writes below, and this process would then erase
    /// that fresh claim — leaving the offer looking unhandled so the next poll
    /// inserts the same transcript a second time. The app owns `offer.v1`, the
    /// extension owns `claim.v1`, and neither touches the other's key.
    @discardableResult
    public func publishOffer(_ offer: KeyboardPickupOffer) -> KeyboardPickupOffer? {
        let published: KeyboardPickupOffer? = lock.withLock {
            guard let defaults else { return nil }
            writeUnlocked(offer, key: Self.offerKey, to: defaults)
            return offer
        }
        // The offer key is app-owned, so wake the keyboard rather than making
        // a targeted insert wait for its next poll tick (issue #990).
        if published != nil { announceStatusChange() }
        return published
    }

    /// Removes the offer entirely. Used when the app decides the transcript is
    /// no longer on the table at all.
    public func clearOffer() {
        lock.withLock {
            defaults?.removeObject(forKey: Self.offerKey)
            defaults?.removeObject(forKey: Self.claimKey)
            defaults?.synchronize()
        }
    }

    /// The current offer, or `nil` if there is none or it has aged out.
    public func pendingOffer(now: Date = Date()) -> KeyboardPickupOffer? {
        lock.withLock {
            guard let offer = readUnlocked(KeyboardPickupOffer.self, key: Self.offerKey),
                  offer.expiresAt > now else {
                return nil
            }
            return offer
        }
    }

    // MARK: - Claim (extension-owned)

    /// Records that this keyboard has inserted or dismissed `offerID`. Writing
    /// the claim rather than deleting the offer keeps single-writer ownership
    /// intact, and makes a second appearance see the offer as already handled
    /// instead of inserting it twice.
    @discardableResult
    public func claimOffer(_ offerID: UUID, now: Date = Date()) -> KeyboardPickupClaim? {
        lock.withLock {
            guard let defaults else { return nil }
            let claim = KeyboardPickupClaim(offerID: offerID, claimedAt: now)
            writeUnlocked(claim, key: Self.claimKey, to: defaults)
            return claim
        }
    }

    public func claim() -> KeyboardPickupClaim? {
        lock.withLock {
            readUnlocked(KeyboardPickupClaim.self, key: Self.claimKey)
        }
    }

    // MARK: - Preferences (app-owned)

    public func preferences() -> KeyboardDeliveryPreferences {
        lock.withLock {
            readUnlocked(KeyboardDeliveryPreferences.self, key: Self.preferencesKey) ?? .default
        }
    }

    @discardableResult
    public func publishPreferences(
        _ preferences: KeyboardDeliveryPreferences
    ) -> KeyboardDeliveryPreferences {
        lock.withLock {
            guard let defaults else { return preferences }
            writeUnlocked(preferences, key: Self.preferencesKey, to: defaults)
            return preferences
        }
    }

    // MARK: - Storage

    /// Values written by a future schema are ignored rather than migrated, so
    /// an older keyboard falls back to its safe default instead of guessing.
    private func readUnlocked<Value: KeyboardVersionedSelection>(
        _ type: Value.Type,
        key: String
    ) -> Value? {
        guard let data = defaults?.data(forKey: key),
              let value = try? JSONDecoder().decode(Value.self, from: data),
              value.schemaVersion == Value.schemaVersion else {
            return nil
        }
        return value
    }

    private func writeUnlocked<Value: KeyboardVersionedSelection>(
        _ value: Value,
        key: String,
        to defaults: UserDefaults
    ) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
        defaults.synchronize()
    }
}

extension KeyboardTargetRecord: KeyboardVersionedSelection {}
extension KeyboardPickupOffer: KeyboardVersionedSelection {}
extension KeyboardPickupClaim: KeyboardVersionedSelection {}
extension KeyboardDeliveryPreferences: KeyboardVersionedSelection {}
