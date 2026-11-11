#if os(iOS)
import Foundation
import SpeakCore

/// The Keychain side of `AppSettings`' API keys: the canonical store, edit-ordered
/// writes and generation-checked reloads.
///
/// Latest-edit-wins bookkeeping per credential identifier. Each write waits
/// for the previous one, so an older value can never land after a newer one;
/// a reload publishes a stored value only once every local edit is settled.
@MainActor
final class AppSettingsSecrets {
    let storage: SecureStorage
    /// Only the shared production store migrates pre-unification iOS keys.
    let migratesLegacyCredentials: Bool
    /// Coalesces bootstrap and recording callers; a failed read remains retryable.
    var loadTask: Task<Bool, Never>?
    /// Reloads keys another process or CloudKit sync changed.
    var keyChangeObserver: NSObjectProtocol?
    /// Retries loading once protected data becomes available after a locked launch.
    var protectedDataObserver: NSObjectProtocol?

    private static let logger = SpeakLogger.logger(category: "AppSettings")
    private var writeTails: [String: Task<Void, Never>] = [:]
    private var editGenerations: [String: UInt64] = [:]
    private var settledGenerations: [String: UInt64] = [:]
    /// Non-zero while a reload publishes stored values, so they are not written back.
    private var reloadDepth = 0

    init(storage: SecureStorage, migratesLegacyCredentials: Bool) {
        self.storage = storage
        self.migratesLegacyCredentials = migratesLegacyCredentials
    }

    deinit {
        if let protectedDataObserver {
            NotificationCenter.default.removeObserver(protectedDataObserver)
        }
        if let keyChangeObserver {
            NotificationCenter.default.removeObserver(keyChangeObserver)
        }
    }

    /// Persists (or clears when empty) an API key on the canonical secure store.
    /// Keychain failures are logged rather than silently dropped so a key that
    /// appears saved but didn't persist is diagnosable from logs.
    ///
    /// Writes for one identifier run strictly in edit order: each waits for the
    /// previous write, and a write already superseded by a newer edit is skipped
    /// because that newer write is queued behind it.
    func persist(_ value: String, identifier: String) {
        guard reloadDepth == 0 else { return }
        let generation = editGenerations[identifier, default: 0] &+ 1
        editGenerations[identifier] = generation
        let previousWrite = writeTails[identifier]
        writeTails[identifier] = Task {
            if let previousWrite { await previousWrite.value }
            guard self.editGenerations[identifier] == generation else { return }
            do {
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try await self.storage.removeSecret(identifier: identifier)
                } else {
                    try await self.storage.storeSecret(value, identifier: identifier)
                }
            } catch {
                Self.logger.error(
                    "Failed to persist secret \(identifier, privacy: .public): \(error.localizedDescription)"
                )
            }
            self.settledGenerations[identifier] = generation
        }
    }

    /// Waits until every queued API-key write has finished.
    func awaitPendingWrites() async {
        for write in Array(writeTails.values) {
            await write.value
        }
    }

    /// Publishes one stored credential without persisting it back. The value is
    /// skipped when the store cannot be read, when a local edit is still being
    /// written, or when the user edited the key while it was being read, so a
    /// reload can never replace a newer local edit with an older stored value.
    func reload(identifier: String, publish: (String) -> Void) async {
        let generation = editGenerations[identifier, default: 0]
        let stored: String
        do {
            stored = try await storage.secret(identifier: identifier)
        } catch SecureStorageError.valueNotFound {
            stored = ""
        } catch {
            return
        }
        guard editGenerations[identifier, default: 0] == generation,
              settledGenerations[identifier, default: 0] == generation else { return }
        // Held only around the synchronous assignment, so an edit made while
        // the reload awaits the store is still persisted.
        reloadDepth += 1
        defer { reloadDepth -= 1 }
        publish(stored)
    }
}
#endif
