import CloudKit
import Foundation
import SpeakCore

// MARK: - One-time copy from the legacy container (#1119)

extension HistorySyncEngine {
    /// Copies History from this platform's legacy CloudKit container into the
    /// shared one, once per device. Records go through `upload(entry:)`, the
    /// normal push path, so a newer copy already in the shared container wins
    /// and the delegate records every acknowledgement. The legacy records are
    /// left in place. Call after `initialize(delegate:)` and before the first
    /// `sync()`, which then fetches the copied records into local History.
    /// Returns whether the copy is complete; on failure it runs again on the
    /// next call.
    @discardableResult
    public func migrateLegacyContainerHistoryIfNeeded() async -> Bool {
        guard SyncConfiguration.legacyContainerIdentifier != nil,
              SyncConfiguration.legacyContainerIdentifier != SyncConfiguration.containerIdentifier else {
            return true
        }
        let legacy = CloudKitHistorySyncTransport(database: { SyncConfiguration.legacyPrivateDatabase })
        return await migrateHistory(from: legacy)
    }

    func migrateHistory(from legacy: HistorySyncTransport) async -> Bool {
        let completedKey = SyncContainerTransition.historyMigrationCompletedKey
        guard !defaults.bool(forKey: completedKey) else { return true }
        guard isSyncEnabled, state.isCloudAvailable else { return false }
        let log = SpeakLogger.logger(category: "HistorySync")

        var entries: [UUID: SyncableHistoryEntry] = [:]
        do {
            var token: Data?
            var page: HistoryChangePage
            repeat {
                page = try await legacy.fetchChanges(after: token)
                for change in page.changes {
                    switch change {
                    case .changed(let entry): entries[entry.id] = entry
                    case .deleted(let id): entries.removeValue(forKey: id)
                    }
                }
                token = page.serverChangeTokenData
            } while page.moreComing
        } catch where SyncContainerTransition.isMissingZone(error) {
            // The legacy container never held History on this account.
        } catch {
            log.warning("Legacy-container History read failed: \(error.localizedDescription)")
            return false
        }

        var copied = 0
        for entry in entries.values.sorted(by: { $0.createdAt < $1.createdAt }) {
            do {
                try await upload(entry: entry)
                copied += 1
            } catch {
                log.warning("Legacy-container History copy stopped: \(error.localizedDescription)")
                return false
            }
        }
        defaults.set(true, forKey: completedKey)
        log.info("Copied \(copied) History entries from the legacy container")
        return true
    }

}
