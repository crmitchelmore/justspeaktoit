import Foundation
import SpeakCore

/// Local key mutations still waiting to reach CloudKit, mirrored to
/// `UserDefaults` so a relaunch resumes them. Every change updates the
/// persisted copy and memory together, in that order.
struct KeySyncPendingMutations {
    private static let keyPrefix = "speak.keysync.pending."

    private let defaults: UserDefaults
    private var byIdentifier: [String: PendingKeySyncMutation]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.byIdentifier = Self.loadPersisted(defaults: defaults)
    }

    static func key(identifier: String) -> String {
        keyPrefix + identifier
    }

    var identifiers: Dictionary<String, PendingKeySyncMutation>.Keys { byIdentifier.keys }

    /// The mutation held in memory for `identifier`.
    subscript(identifier: String) -> PendingKeySyncMutation? {
        byIdentifier[identifier]
    }

    /// The in-memory mutation, else the persisted copy another path may have written.
    func current(_ identifier: String) -> PendingKeySyncMutation? {
        byIdentifier[identifier] ?? persisted(identifier)
    }

    func persisted(_ identifier: String) -> PendingKeySyncMutation? {
        guard let data = defaults.data(forKey: Self.key(identifier: identifier)) else {
            return nil
        }
        return try? JSONDecoder().decode(PendingKeySyncMutation.self, from: data)
    }

    mutating func record(_ mutation: PendingKeySyncMutation) {
        if let data = try? JSONEncoder().encode(mutation) {
            defaults.set(data, forKey: Self.key(identifier: mutation.identifier))
        }
        byIdentifier[mutation.identifier] = mutation
    }

    /// Replaces memory with whatever is persisted.
    mutating func reloadPersisted() {
        byIdentifier = Self.loadPersisted(defaults: defaults)
    }

    /// Clears `mutation` only while both copies still hold that exact operation,
    /// so a newer local edit recorded meanwhile is kept.
    mutating func clear(ifMatching mutation: PendingKeySyncMutation) {
        guard byIdentifier[mutation.identifier]?.operationID == mutation.operationID,
              persisted(mutation.identifier)?.operationID == mutation.operationID else {
            return
        }
        byIdentifier[mutation.identifier] = nil
        defaults.removeObject(forKey: Self.key(identifier: mutation.identifier))
    }

    mutating func removeAll() {
        byIdentifier.removeAll()
        for identifier in CloudKitKeySync.syncableIdentifiers {
            defaults.removeObject(forKey: Self.key(identifier: identifier))
        }
    }

    private static func loadPersisted(defaults: UserDefaults) -> [String: PendingKeySyncMutation] {
        CloudKitKeySync.syncableIdentifiers.reduce(into: [:]) { mutations, identifier in
            guard let data = defaults.data(forKey: key(identifier: identifier)) else { return }
            mutations[identifier] = try? JSONDecoder().decode(PendingKeySyncMutation.self, from: data)
        }
    }
}

extension PendingKeySyncMutation {
    /// The mutation a `SecureStorage.didChangeSecretNotification` describes.
    init(identifier: String, changeNotification notification: Notification, now: () -> Date) {
        let userInfo = notification.userInfo
        let operation = userInfo?[SecureStorage.NotificationUserInfoKey.operation] as? String
        self.init(
            operationID: UUID(),
            identifier: identifier,
            updatedAt: userInfo?[SecureStorage.NotificationUserInfoKey.updatedAt] as? Date ?? now(),
            kind: operation == "remove" ? .deletion : .update
        )
    }
}

/// Serialises enable, disable and account changes. Waiters resume in arrival order.
@MainActor
final class KeySyncLifecycleLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}
