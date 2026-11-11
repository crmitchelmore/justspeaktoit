// swiftlint:disable file_length
#if os(iOS)
import Foundation
import SpeakCore
import SpeakSync
import os.log

private let logger = SpeakLogger.logger(category: "iOSHistoryManager")

/// MainActor presentation and sync bookkeeping over one ordered persistence worker.
@MainActor
// swiftlint:disable:next type_body_length
public final class iOSHistoryManager: ObservableObject { // swiftlint:disable:this type_name
    public static let shared = iOSHistoryManager()
    @Published public private(set) var items: [iOSHistoryItem] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var reprocessingIDs: Set<UUID> = []
    @Published public private(set) var persistenceError: String?
    @Published public private(set) var isStorageReady = false
    @Published private(set) var syncedIDs: Set<UUID> = []

    private let persistence: IOSHistoryPersistence
    private let startSync: ((iOSHistoryManager) async -> Void)?
    private let userDefaults: UserDefaults
    private let removeNotificationClaims: (Set<UUID>) -> Void
    private let syncEnabled: Bool
    private var syncStarted = false
    private var hasLoadedFromDisk = false
    private var ledger = IOSHistoryRevisionLedger()
    private var remote = IOSHistoryRemoteLedger()
    private let uploadEntry: @MainActor (SyncableHistoryEntry) async throws -> Void
    private let deleteEntry: @MainActor (UUID) async throws -> Void
    private let uploadSettled: @MainActor (UUID) -> Void
    private var pendingRemoteCommit: Task<Void, Never>?
    private var lifecycleObservers: IOSHistoryLifecycleObservers?
    private var loadingCount = 0

    static let syncedIDsKey = "speak.sync.syncedHistoryIDs"

    /// Runs at launch before History or key sync read their state, so a build
    /// that moved to another CloudKit container re-pushes local History there
    /// (#1119). Idempotent: only the first call after a move resets anything.
    @discardableResult
    public static func resetSyncStateIfContainerChanged(defaults: UserDefaults = .standard) -> Bool {
        SyncContainerTransition.resetIfContainerChanged(defaults: defaults, additionalKeys: [syncedIDsKey])
    }

    static let remoteCommitDebounce: Duration = .milliseconds(250)
    private var currentItemIDs: Set<UUID> { Set(items.map(\.id)) }
    private var reconciledSyncedIDs: Set<UUID> { syncedIDs.intersection(currentItemIDs) }
    public var syncedCount: Int { reconciledSyncedIDs.count }
    public var unsyncedCount: Int { items.count - syncedCount }

    public func isSynced(_ item: iOSHistoryItem) -> Bool {
        currentItemIDs.contains(item.id) && syncedIDs.contains(item.id)
    }

    private convenience init() {
        Self.resetSyncStateIfContainerChanged()
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.init(
            fileURL: documentsURL.appendingPathComponent("transcription-history.json"),
            syncEnabled: true, userDefaults: .standard, loadImmediately: false,
            removeNotificationClaims: { TranscriptReadyNotificationCoordinator.shared.retireNotifications(for: $0) }
        )
    }

    /// Compatibility initialization loads before returning. Production singleton
    /// callers explicitly await loading instead; no IO is performed constructing it.
    init(
        fileURL: URL, syncEnabled: Bool, userDefaults: UserDefaults = .standard,
        storageIO: IOSHistoryPersistence.StorageIO = .init(),
        startSync: ((iOSHistoryManager) async -> Void)? = nil,
        loadImmediately: Bool = true,
        uploadEntry: @escaping @MainActor (SyncableHistoryEntry) async throws -> Void = {
            try await HistorySyncEngine.shared.upload(entry: $0)
        },
        deleteEntry: @escaping @MainActor (UUID) async throws -> Void = {
            try await HistorySyncEngine.shared.delete(entryID: $0)
        },
        uploadSettled: @escaping @MainActor (UUID) -> Void = { _ in },
        removeNotificationClaims: @escaping (Set<UUID>) -> Void = { _ in }
    ) {
        persistence = IOSHistoryPersistence(fileURL: fileURL, storageIO: storageIO)
        self.startSync = startSync
        self.syncEnabled = syncEnabled
        self.userDefaults = userDefaults
        self.removeNotificationClaims = removeNotificationClaims
        self.uploadEntry = uploadEntry
        self.deleteEntry = deleteEntry
        self.uploadSettled = uploadSettled
        loadSyncedIDs()
        if loadImmediately { _ = performSynchronously(.load) }
        lifecycleObservers = IOSHistoryLifecycleObservers(history: self)
    }

    deinit {
        pendingRemoteCommit?.cancel()
    }

    // MARK: - Ordered execution

    private func publish(_ result: IOSHistoryPersistence.Result) {
        guard ledger.accept(result) else { return }
        items = result.rows
        let wasReady = isStorageReady
        isStorageReady = result.isReady
        hasLoadedFromDisk = isStorageReady
        persistenceError = result.errorMessage
        if isStorageReady && !wasReady { syncedIDs.subtract(result.recoveredIDs) }
        pruneStaleSyncedIDs()
        startSyncIfReady()
    }

    @discardableResult
    private func performSynchronously(_ operation: IOSHistoryPersistence.Operation) -> IOSHistoryPersistence.Result {
        let result = persistence.synchronously(operation, revision: ledger.admit(operation))
        publish(result)
        return result
    }

    private func performAndWait(_ operation: IOSHistoryPersistence.Operation) async -> IOSHistoryPersistence.Result {
        let admittedRevision = ledger.admit(operation)
        // Enqueue before the first suspension, rather than relying on actor mailbox order.
        let ticket = persistence.admit(operation, revision: admittedRevision)
        let showsLoading: Bool
        switch operation {
        case .load, .retry: showsLoading = !isStorageReady
        default: showsLoading = false
        }
        if showsLoading { loadingCount += 1; isLoading = true }
        let result = await persistence.result(for: ticket)
        if showsLoading { loadingCount -= 1; isLoading = loadingCount != 0 }
        publish(result)
        return result
    }

    private func ownsDeletion(_ id: UUID, result: IOSHistoryPersistence.Result) -> Bool {
        ledger.ownsDeletion(id, result: result, isVisible: currentItemIDs.contains(id))
    }

    /// Legacy adapters block on the same serial worker, and never return optimistic durability.
    public func ensureLoaded() { if !isStorageReady { _ = performSynchronously(.retry) } }
    public func retryPersistence() { _ = performSynchronously(.retry) }
    public func flushPendingChanges() {
        _ = commitRemoteChangesNow()
        if persistenceError != nil { retryPersistence() }
    }

    func loadIfNeededAndWait() async { _ = await performAndWait(isStorageReady ? .load : .retry) }
    func retryPersistenceAndWait() async { _ = await performAndWait(.retry) }
    func flushPendingChangesAndWait() async {
        _ = await commitRemoteChangesAndWait()
        if persistenceError != nil { await retryPersistenceAndWait() }
    }

    // MARK: - Local mutations and truthful receipts

    public func add(_ item: iOSHistoryItem) { _ = upsertReportingDurability(item) }

    @discardableResult
    public func upsertReportingDurability(_ item: iOSHistoryItem) -> Bool {
        finishUpsert(performSynchronously(.upsert(item)), id: item.id)
    }

    /// Cancellation does not undo an already admitted write. Its owned receipt is
    /// returned even when a newer operation has superseded the visible snapshot.
    @discardableResult
    func upsertAndWait(_ item: iOSHistoryItem) async -> Bool {
        finishUpsert(await performAndWait(.upsert(item)), id: item.id)
    }

    /// Offline transcript upgrade (issue #999). The untouched check runs on the
    /// persistence worker, after every mutation admitted before it.
    func replaceIfUntouchedAndWait(_ item: iOSHistoryItem, fingerprint: String, filedAt: Date) async -> Bool {
        finishUpsert(
            await performAndWait(.replaceIfUntouched(item, fingerprint: fingerprint, filedAt: filedAt)),
            id: item.id
        )
    }

    private func finishUpsert(_ result: IOSHistoryPersistence.Result, id: UUID) -> Bool {
        if ledger.isUnchanged(id, since: result.revision) { syncedIDs.remove(id); saveSyncedIDs() }
        guard result.durable else { return false }
        guard syncEnabled, result.isReady, result.versions[id] != nil,
              let item = result.rows.first(where: { $0.id == id }),
              ledger.ownsMutation(id, result: result) else { return true }
        remote.beginDirectUpload(id)
        Task {
            defer {
                self.remote.endDirectUpload(id)
                self.uploadSettled(id)
            }
            guard self.ledger.ownsMutation(id, result: result) else { return }
            do {
                // The generic ID-only delegate callback occurs inside this await.
                // Only this captured-revision wrapper may acknowledge its result.
                try await self.uploadEntry(item.toSyncable())
                guard self.ledger.ownsMutation(id, result: result) else { return }
                self.syncedIDs.insert(id)
                self.saveSyncedIDs()
            } catch is HistorySyncDisabledError {
                // Retain the pending local revision until sync is enabled.
            } catch {
                logger.error("Failed to upload item: \(error.localizedDescription, privacy: .public)")
            }
        }
        return true
    }

    @discardableResult
    public func recordTranscription(text: String, model: String, duration: TimeInterval) -> iOSHistoryItem? {
        recordTranscription(text: text, model: model, duration: duration, errorMessage: nil)
    }

    @discardableResult
    func recordTranscription(
        text: String, model: String, duration: TimeInterval, errorMessage: String?
    ) -> iOSHistoryItem? {
        guard let item = iOSHistoryItem.recordedTranscript(
            text: text, model: model, duration: duration, errorMessage: errorMessage
        ), upsertReportingDurability(item) else { return nil }
        return item
    }

    func recordTranscriptionAndWait(
        text: String, model: String, duration: TimeInterval, errorMessage: String? = nil
    ) async -> iOSHistoryItem? {
        await recordTranscriptionAndWait(
            text: text, model: model, duration: duration, errorMessage: errorMessage, requestContext: nil
        )
    }

    func recordTranscriptionAndWait(
        text: String, model: String, duration: TimeInterval, errorMessage: String? = nil,
        requestContext: RequestDiagnosticContext?
    ) async -> iOSHistoryItem? {
        await recordTranscriptionAndWait(
            text: text, model: model, duration: duration, errorMessage: errorMessage,
            requestContext: requestContext, requestFailure: nil
        )
    }

    func recordTranscriptionAndWait(
        text: String, model: String, duration: TimeInterval, errorMessage: String? = nil,
        requestContext: RequestDiagnosticContext? = nil, requestFailure: RequestDiagnosticContext.Failure?
    ) async -> iOSHistoryItem? {
        guard let item = iOSHistoryItem.recordedTranscript(
            text: text, model: model, duration: duration, errorMessage: errorMessage,
            requestContext: requestContext, requestFailure: requestFailure
        ), await upsertAndWait(item) else { return nil }
        return item
    }

    public func remove(_ item: iOSHistoryItem) { finishRemoval(performSynchronously(.remove(item.id))) }
    public func clearAll() { finishRemoval(performSynchronously(.clear), clearingAll: true) }
    func removeAndWait(_ item: iOSHistoryItem) async { finishRemoval(await performAndWait(.remove(item.id))) }
    func clearAllAndWait() async { finishRemoval(await performAndWait(.clear), clearingAll: true) }

    private func finishRemoval(_ result: IOSHistoryPersistence.Result, clearingAll: Bool = false) {
        guard result.durable else { return }
        if clearingAll {
            OfflineTranscriptUpgradeStore.shared.removeAll()
        } else {
            OfflineTranscriptUpgradeStore.shared.remove(historyIDs: result.removedIDs)
        }
        // A newer re-insertion owns its notifications and CloudKit row.
        let deleted = result.removedIDs.filter { ownsDeletion($0, result: result) }
        removeNotificationClaims(deleted)
        syncedIDs.subtract(deleted)
        saveSyncedIDs()
        if clearingAll && ledger.hasNoInsertion(after: result.revision) {
            TranscriptHandoffPublisher.invalidate()
        } else {
            for id in deleted { TranscriptHandoffPublisher.invalidateIfAdvertising(entryID: id) }
        }
        guard syncEnabled else { return }
        Task {
            for id in deleted where self.ownsDeletion(id, result: result) {
                try? await self.deleteEntry(id)
            }
        }
    }

    public func macLaneOutcome(for item: iOSHistoryItem?) -> MacLaneOutcome {
        guard item != nil, syncEnabled, HistorySyncEngine.shared.isSyncEnabled else { return .notAttempted }
        return HistorySyncEngine.shared.state.isCloudAvailable ? .queuedForICloud : .iCloudUnavailable
    }

    public func triggerSync() async {
        await retryPersistenceAndWait()
        guard syncEnabled, isStorageReady else { return }
        await HistorySyncEngine.shared.sync()
    }

    // MARK: - Post-processing

    public func reprocess(_ item: iOSHistoryItem) async {
        let settings = AppSettings.shared
        guard settings.hasPostProcessingKey else {
            await setErrorAndWait(
                "Add a \(settings.postProcessingKeyProviderName) API key in Settings to reprocess.", for: item.id
            )
            return
        }
        guard !reprocessingIDs.contains(item.id) else { return }
        reprocessingIDs.insert(item.id)
        defer { reprocessingIDs.remove(item.id) }
        do {
            let polished = try await iOSPostProcessingManager.shared.polish(
                text: item.transcription, model: settings.postProcessingModel,
                apiKey: settings.postProcessingAPIKey(for: settings.postProcessingModel)
            )
            try Task.checkCancellation()
            await setPostProcessedAndWait(polished, for: item.id)
        } catch is CancellationError {
            // An unaccepted provider result has no history mutation to admit.
        } catch { await setErrorAndWait(error.localizedDescription, for: item.id) }
    }

    public func setPostProcessed(_ processed: String, for id: UUID) {
        setPostProcessed(processed, for: id, preservingError: nil)
    }

    func setPostProcessed(_ processed: String, for id: UUID, preservingError: String?) {
        reprocessingIDs.remove(id)
        _ = finishUpsert(performSynchronously(.processed(id, processed, preservingError)), id: id)
    }

    func setPostProcessedAndWait(_ processed: String, for id: UUID, preservingError: String? = nil) async {
        _ = finishUpsert(await performAndWait(.processed(id, processed, preservingError)), id: id)
        reprocessingIDs.remove(id)
    }

    public func beginPostProcessing(for id: UUID) { reprocessingIDs.insert(id) }
    public func endPostProcessing(for id: UUID) { reprocessingIDs.remove(id) }
    public func setError(_ message: String, for id: UUID) { _ = performSynchronously(.error(id, message)) }
    func setErrorAndWait(_ message: String, for id: UUID) async { _ = await performAndWait(.error(id, message)) }
    public func isReprocessing(_ item: iOSHistoryItem) -> Bool { reprocessingIDs.contains(item.id) }

    // MARK: - Debounced sync commits

    private func scheduleRemoteCommit() {
        pendingRemoteCommit?.cancel()
        pendingRemoteCommit = Task { [weak self] in
            try? await Task.sleep(for: Self.remoteCommitDebounce)
            guard !Task.isCancelled else { return }
            _ = await self?.commitRemoteChangesAndWait()
        }
    }

    private func finishRemoteCommit(_ result: IOSHistoryPersistence.Result, target: UInt64) -> Bool {
        guard result.durable else { return false }
        for (id, version) in remote.finishCommit(revision: result.revision, target: target) where ledger.isCurrent(
            id, version: version, receiptRevision: result.revision
        ) { syncedIDs.insert(id) }
        pruneStaleSyncedIDs()
        saveSyncedIDs()
        return true
    }

    @discardableResult
    private func commitRemoteChangesNow() -> Bool {
        pendingRemoteCommit?.cancel()
        pendingRemoteCommit = nil
        let target = remote.uncommittedRevision
        guard target != 0 else { return true }
        return finishRemoteCommit(performSynchronously(.commit), target: target)
    }

    private func commitRemoteChangesAndWait() async -> Bool {
        pendingRemoteCommit?.cancel()
        pendingRemoteCommit = nil
        let target = remote.uncommittedRevision
        guard target != 0 else { return true }
        return finishRemoteCommit(await performAndWait(.commit), target: target)
    }

    private func startSyncIfReady() {
        guard syncEnabled, isStorageReady, !syncStarted else { return }
        syncStarted = true
        Task {
            if let startSync { await startSync(self) } else {
                await HistorySyncEngine.shared.initialize(delegate: self)
                await HistorySyncEngine.shared.sync()
            }
        }
    }

    private func loadSyncedIDs() {
        if let strings = userDefaults.stringArray(forKey: Self.syncedIDsKey) {
            syncedIDs = Set(strings.compactMap { UUID(uuidString: $0) })
        }
    }
    private func saveSyncedIDs() { userDefaults.set(syncedIDs.map(\.uuidString), forKey: Self.syncedIDsKey) }
    private func pruneStaleSyncedIDs() {
        guard hasLoadedFromDisk else { return }
        syncedIDs = reconciledSyncedIDs
        saveSyncedIDs()
    }
}

extension iOSHistoryManager: HistorySyncDurabilityDelegate {
    public func persistRemoteChanges() async throws {
        guard await commitRemoteChangesAndWait() else { throw CocoaError(.fileWriteUnknown) }
    }

    public func pendingEntries() -> [SyncableHistoryEntry] {
        pruneStaleSyncedIDs()
        let pending = items.filter { item in
            guard !syncedIDs.contains(item.id), let version = ledger.versions[item.id] else { return false }
            return ledger.isCurrent(item.id, version: version, receiptRevision: ledger.publishedRevision)
        }
        // Status queries may run while an upload is suspended. Retain the first
        // offer until its acknowledgement is consumed, rather than rebinding an
        // old ID-only callback to a later local edit. Ambiguity costs a retry.
        for item in pending { remote.offer(item.id, version: ledger.versions[item.id]) }
        return pending.map { $0.toSyncable() }
    }

    public func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) async {
        let result = await performAndWait(.remote(iOSHistoryItem.fromSyncable(entry)))
        for id in result.remoteAcknowledgedIDs {
            if let version = result.versions[id] { remote.recordAcknowledged(id, version: version) }
        }
        for id in result.remoteNewerLocalIDs where ledger.versions[id] == result.versions[id]
            && ledger.isUnchanged(id, since: result.revision) { syncedIDs.remove(id) }
        remote.recordUncommitted(result.revision)
        scheduleRemoteCommit()
    }

    public func didDeleteRemoteEntry(id: UUID) async {
        let result = await performAndWait(.remoteDelete(id))
        syncedIDs.remove(id)
        OfflineTranscriptUpgradeStore.shared.remove(historyID: id)
        if result.durable { saveSyncedIDs() }
        if !result.durable { remote.recordUncommitted(result.revision) }
        if ownsDeletion(id, result: result) {
            TranscriptHandoffPublisher.invalidateIfAdvertising(entryID: id)
        }
    }

    public func didAcknowledgeSyncedEntries(ids: Set<UUID>) async {
        let offered = remote.unraced(offersAmong: ids)
        guard await commitRemoteChangesAndWait() else { return }
        for (id, version) in offered {
            guard remote.consume(id, version: version) else { continue }
            if ledger.isCurrent(id, version: version, receiptRevision: ledger.publishedRevision) {
                syncedIDs.insert(id)
            }
        }
        pruneStaleSyncedIDs()
        saveSyncedIDs()
    }
}
#endif
