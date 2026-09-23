import CloudKit
import Combine
import Foundation
import SpeakCore
import os.log

/// Delegate protocol that platforms implement to reconcile synced entries.
@MainActor
public protocol HistorySyncDelegate: AnyObject {
    /// Return local entries that are not currently acknowledged by CloudKit.
    func pendingEntries() -> [SyncableHistoryEntry]

    /// Reconcile a new, duplicate, or updated entry from CloudKit.
    func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) async

    /// Reconcile a CloudKit tombstone.
    func didDeleteRemoteEntry(id: UUID) async

    /// Record IDs that CloudKit has acknowledged.
    func didAcknowledgeSyncedEntries(ids: Set<UUID>) async
}

/// Optional platform durability boundary. Existing delegates retain their
/// behaviour; adopting stores must commit before the fetch token advances.
@MainActor
public protocol HistorySyncDurabilityDelegate: HistorySyncDelegate {
    func persistRemoteChanges() async throws
}

/// Main sync engine handling CloudKit operations for transcription history.
///
/// Reconciliation is the shared `HistorySyncCoordinator`, run on the main
/// actor; this class keeps the native account, zone and subscription setup and
/// publishes the coordinator's status through `SyncState`.
@MainActor
public final class HistorySyncEngine: ObservableObject {
    @Published public private(set) var state: SyncState

    public static let shared = HistorySyncEngine()

    /// An upper bound on back-to-back passes; see `HistorySyncCoordinator`.
    static let maxCoalescedPasses = HistorySyncCoordinator.maxCoalescedPasses

    private weak var delegate: HistorySyncDelegate?
    private let coordinator: HistorySyncCoordinator
    private let defaults: UserDefaults
    private let log = SpeakLogger.logger(category: "HistorySync")

    private convenience init() {
        self.init(
            transport: CloudKitHistorySyncTransport(),
            defaults: .standard,
            cloudAvailable: false
        )
    }

    init(
        transport: HistorySyncTransport,
        defaults: UserDefaults,
        cloudAvailable: Bool,
        delegate: HistorySyncDelegate? = nil
    ) {
        let state = SyncState()
        state.isCloudAvailable = cloudAvailable
        let eventLog = SpeakLogger.logger(category: "HistorySync")
        self.state = state
        self.defaults = defaults
        self.delegate = delegate
        coordinator = HistorySyncCoordinator(
            transport: transport,
            tokenStore: UserDefaultsSyncChangeTokenStore(defaults: defaults, key: SyncConfiguration.syncTokenKey),
            cloudAvailable: cloudAvailable,
            observer: SyncStateMirror(state: state),
            events: { Self.write($0, to: eventLog) }
        )
    }

    public func initialize(delegate: HistorySyncDelegate) async {
        self.delegate = delegate
        await checkCloudAvailability()
        if state.isCloudAvailable {
            await setupCloudKitInfrastructure()
        }
    }

    /// Manually trigger a complete fetch, reconciliation, and upload pass.
    ///
    /// A trigger that arrives while a pass is running is not dropped: it is
    /// remembered and a follow-up pass runs when this one ends.
    public func sync() async {
        await coordinator.sync(store: delegateStore())
    }

    /// Upload a single entry and acknowledge it only after CloudKit confirms it.
    public func upload(entry: SyncableHistoryEntry) async throws {
        try await coordinator.upload(entry: entry, store: delegateStore())
    }

    public func delete(entryID: UUID) async throws {
        try await coordinator.delete(entryID: entryID)
    }

    /// The delegate as a shared-coordinator store for one call, or `nil`.
    private func delegateStore() -> DelegateHistoryStore? {
        delegate.map(DelegateHistoryStore.init)
    }

    private func checkCloudAvailability() async {
        guard SyncConfiguration.hasCloudKitEntitlement else {
            await coordinator.updateCloudAvailability(false, error: SyncError.cloudUnavailable)
            log.warning("CloudKit entitlement missing; history sync disabled")
            return
        }
        do {
            let status = try await SyncConfiguration.container?.accountStatus() ?? .noAccount
            let isAvailable = status == .available
            await coordinator.updateCloudAvailability(
                isAvailable,
                error: isAvailable ? nil : SyncError.cloudUnavailable
            )
        } catch {
            await coordinator.updateCloudAvailability(false, error: SyncError.cloudKit(error))
            log.warning("iCloud check failed: \(error.localizedDescription)")
        }
    }

    private func setupCloudKitInfrastructure() async {
        if !defaults.bool(forKey: SyncConfiguration.zoneCreatedKey) {
            do {
                try await createCustomZone()
                defaults.set(true, forKey: SyncConfiguration.zoneCreatedKey)
            } catch {
                log.error("Zone creation failed: \(error.localizedDescription)")
            }
        }
        if !defaults.bool(forKey: SyncConfiguration.subscriptionCreatedKey) {
            do {
                try await createSubscription()
                defaults.set(true, forKey: SyncConfiguration.subscriptionCreatedKey)
            } catch {
                log.warning("Subscription failed: \(error.localizedDescription)")
            }
        }
    }

    private func createCustomZone() async throws {
        guard let database = SyncConfiguration.privateDatabase else { return }
        do {
            _ = try await database.save(SyncConfiguration.recordZone)
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Zone already exists.
        }
    }

    private func createSubscription() async throws {
        guard let database = SyncConfiguration.privateDatabase else { return }
        let subscription = CKDatabaseSubscription(subscriptionID: SyncConfiguration.historySubscriptionID)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
    }

    /// The log lines this engine has always written, with their privacy defaults.
    private nonisolated static func write(_ event: HistorySyncEvent, to log: Logger) {
        switch event {
        case .syncRequestedWhileCloudUnavailable:
            log.warning("Sync requested but iCloud unavailable")
        case .followUpQueued:
            log.info("Sync already in progress; queued a follow-up reconciliation")
        case .passCompleted:
            log.info("Sync reconciliation completed successfully")
        case .passFailed(let error):
            log.error("Sync failed: \(error.localizedDescription)")
        case .uploaded(let id):
            log.debug("Uploaded entry: \(id.uuidString)")
        case .deleted(let id):
            log.debug("Deleted entry: \(id.uuidString)")
        case .reconciledRemoteChanges(let count):
            log.info("Reconciled \(count) final remote changes")
        }
    }
}

/// Holds the delegate for the duration of one coordinator call, so a pass
/// always reconciles against the delegate that started it.
@MainActor
private final class DelegateHistoryStore: HistorySyncStore {
    private let delegate: HistorySyncDelegate

    init(_ delegate: HistorySyncDelegate) {
        self.delegate = delegate
    }

    func pendingEntries() async -> [SyncableHistoryEntry] {
        delegate.pendingEntries()
    }

    func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) async {
        await delegate.didReceiveRemoteEntry(entry)
    }

    func didDeleteRemoteEntry(id: UUID) async {
        await delegate.didDeleteRemoteEntry(id: id)
    }

    func didAcknowledgeSyncedEntries(ids: Set<UUID>) async {
        await delegate.didAcknowledgeSyncedEntries(ids: ids)
    }

    func persistRemoteChanges() async throws {
        try await (delegate as? HistorySyncDurabilityDelegate)?.persistRemoteChanges()
    }
}

/// Publishes each coordinator assignment through the engine's `SyncState`.
@MainActor
private final class SyncStateMirror: HistorySyncStatusObserver {
    private let state: SyncState

    init(state: SyncState) {
        self.state = state
    }

    func historySync(_ status: HistorySyncStatus, didChange field: HistorySyncStatus.Field) async {
        state.apply(status, changed: field)
    }
}
