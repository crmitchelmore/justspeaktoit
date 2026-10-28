// swiftlint:disable file_length
#if os(iOS)
import Foundation
import SpeakCore
import SpeakSync
import UIKit
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
    private var revision: UInt64 = 0
    private var publishedRevision: UInt64 = 0
    private var versions: [UUID: UInt64] = [:]
    private var durableVersions: [UUID: UInt64] = [:]
    private var offeredVersions: [UUID: UInt64] = [:]
    private var latestMutation: [UUID: UInt64] = [:]
    private var latestClear: UInt64 = 0
    private var latestInsertion: [UUID: UInt64] = [:]
    private var directUploads: [UUID: Int] = [:]
    private let uploadEntry: @MainActor (SyncableHistoryEntry) async throws -> Void
    private let deleteEntry: @MainActor (UUID) async throws -> Void
    private let uploadSettled: @MainActor (UUID) -> Void
    private var remotePendingVersions: [UUID: UInt64] = [:]
    private var remoteRevision: UInt64 = 0
    private var pendingRemoteCommit: Task<Void, Never>?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var loadingCount = 0

    static let syncedIDsKey = "speak.sync.syncedHistoryIDs"
    static let remoteCommitDebounce: Duration = .milliseconds(250)
    private var currentItemIDs: Set<UUID> { Set(items.map(\.id)) }
    private var reconciledSyncedIDs: Set<UUID> { syncedIDs.intersection(currentItemIDs) }
    public var syncedCount: Int { reconciledSyncedIDs.count }
    public var unsyncedCount: Int { items.count - syncedCount }

    public func isSynced(_ item: iOSHistoryItem) -> Bool {
        currentItemIDs.contains(item.id) && syncedIDs.contains(item.id)
    }

    private convenience init() {
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
        registerLifecycleFlushObservers()
    }

    deinit {
        pendingRemoteCommit?.cancel()
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
    }

    private func registerLifecycleFlushObservers() {
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { @MainActor [weak self] _ in
            guard let self else { return }
            let assertion = BackgroundTaskAssertion(name: "History flush")
            Task { await self.flushPendingChangesAndWait(); assertion.end() }
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { @MainActor [weak self] _ in
            // Termination provides no guaranteed asynchronous execution window.
            self?.flushPendingChanges()
        })
        lifecycleObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
        ) { @MainActor [weak self] _ in
            Task { await self?.retryPersistenceAndWait() }
        })
    }

    // MARK: - Ordered execution

    private func admission(_ operation: IOSHistoryPersistence.Operation) -> UInt64 {
        revision += 1
        switch operation {
        case .upsert(let item), .remote(let item):
            latestMutation[item.id] = revision
            latestInsertion[item.id] = revision
        case let .processed(id, _, _), let .error(id, _), .remove(let id), .remoteDelete(let id):
            latestMutation[id] = revision
        case .clear: latestClear = revision
        case .load, .retry, .commit: break
        }
        return revision
    }

    private func publish(_ result: IOSHistoryPersistence.Result) {
        guard result.revision >= publishedRevision else { return }
        publishedRevision = result.revision
        items = result.rows
        versions = result.versions
        durableVersions = result.durableVersions
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
        let result = persistence.synchronously(operation, revision: admission(operation))
        publish(result)
        return result
    }

    private func performAndWait(_ operation: IOSHistoryPersistence.Operation) async -> IOSHistoryPersistence.Result {
        let admittedRevision = admission(operation)
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

    private func isCurrent(_ id: UUID, version: UInt64, receiptRevision: UInt64) -> Bool {
        versions[id] == version && durableVersions[id] == version
            && (latestMutation[id] ?? 0) <= receiptRevision && latestClear <= receiptRevision
    }

    private func ownsMutation(_ id: UUID, result: IOSHistoryPersistence.Result) -> Bool {
        (latestMutation[id] ?? 0) <= result.revision && latestClear <= result.revision
            && (publishedRevision <= result.revision || versions[id] == result.versions[id])
    }

    private func ownsDeletion(_ id: UUID, result: IOSHistoryPersistence.Result) -> Bool {
        (latestInsertion[id] ?? 0) <= result.revision
            && !(publishedRevision > result.revision && currentItemIDs.contains(id))
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

    private func finishUpsert(_ result: IOSHistoryPersistence.Result, id: UUID) -> Bool {
        if (latestMutation[id] ?? 0) <= result.revision { syncedIDs.remove(id); saveSyncedIDs() }
        guard result.durable else { return false }
        guard syncEnabled, result.isReady, result.versions[id] != nil,
              let item = result.rows.first(where: { $0.id == id }),
              ownsMutation(id, result: result) else { return true }
        directUploads[id, default: 0] += 1
        Task {
            defer {
                let count = self.directUploads[id, default: 1] - 1
                self.directUploads[id] = count == 0 ? nil : count
                self.uploadSettled(id)
            }
            guard self.ownsMutation(id, result: result) else { return }
            do {
                // The generic ID-only delegate callback occurs inside this await.
                // Only this captured-revision wrapper may acknowledge its result.
                try await self.uploadEntry(item.toSyncable())
                guard self.ownsMutation(id, result: result) else { return }
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
        guard let item = makeItem(text: text, model: model, duration: duration, errorMessage: errorMessage),
              upsertReportingDurability(item) else { return nil }
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
        guard let item = makeItem(text: text, model: model, duration: duration, errorMessage: errorMessage,
                                  requestContext: requestContext, requestFailure: requestFailure),
              await upsertAndWait(item) else { return nil }
        return item
    }

    private func makeItem(
        text: String, model: String, duration: TimeInterval, errorMessage: String?
    ) -> iOSHistoryItem? {
        makeItem(text: text, model: model, duration: duration, errorMessage: errorMessage, requestContext: nil)
    }

    private func makeItem(
        text: String, model: String, duration: TimeInterval, errorMessage: String?,
        requestContext: RequestDiagnosticContext?, requestFailure: RequestDiagnosticContext.Failure? = nil
    ) -> iOSHistoryItem? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return iOSHistoryItem(
            transcription: text, model: model, duration: duration,
            wordCount: text.split(separator: " ").count, errorMessage: errorMessage, requestContext: requestContext,
            requestFailure: requestFailure
        )
    }

    public func remove(_ item: iOSHistoryItem) { finishRemoval(performSynchronously(.remove(item.id))) }
    public func clearAll() { finishRemoval(performSynchronously(.clear), clearingAll: true) }
    func removeAndWait(_ item: iOSHistoryItem) async { finishRemoval(await performAndWait(.remove(item.id))) }
    func clearAllAndWait() async { finishRemoval(await performAndWait(.clear), clearingAll: true) }

    private func finishRemoval(_ result: IOSHistoryPersistence.Result, clearingAll: Bool = false) {
        guard result.durable else { return }
        // A newer re-insertion owns its notifications and CloudKit row.
        let deleted = result.removedIDs.filter { ownsDeletion($0, result: result) }
        removeNotificationClaims(deleted)
        syncedIDs.subtract(deleted)
        saveSyncedIDs()
        if clearingAll && latestInsertion.values.allSatisfy({ $0 <= result.revision }) {
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
        guard settings.hasOpenRouterKey else {
            await setErrorAndWait("Add an OpenRouter API key in Settings to reprocess.", for: item.id)
            return
        }
        guard !reprocessingIDs.contains(item.id) else { return }
        reprocessingIDs.insert(item.id)
        defer { reprocessingIDs.remove(item.id) }
        do {
            let polished = try await iOSPostProcessingManager.shared.polish(
                text: item.transcription, model: settings.postProcessingModel, apiKey: settings.openRouterAPIKey
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
        for (id, version) in remotePendingVersions where isCurrent(
            id, version: version, receiptRevision: result.revision
        ) { syncedIDs.insert(id) }
        remotePendingVersions = remotePendingVersions.filter { $0.value > result.revision }
        if remoteRevision == target { remoteRevision = 0 }
        pruneStaleSyncedIDs()
        saveSyncedIDs()
        return true
    }

    @discardableResult
    private func commitRemoteChangesNow() -> Bool {
        pendingRemoteCommit?.cancel()
        pendingRemoteCommit = nil
        guard remoteRevision != 0 else { return true }
        let target = remoteRevision
        return finishRemoteCommit(performSynchronously(.commit), target: target)
    }

    private func commitRemoteChangesAndWait() async -> Bool {
        pendingRemoteCommit?.cancel()
        pendingRemoteCommit = nil
        guard remoteRevision != 0 else { return true }
        let target = remoteRevision
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
            guard !syncedIDs.contains(item.id), let version = versions[item.id] else { return false }
            return isCurrent(item.id, version: version, receiptRevision: publishedRevision)
        }
        // Status queries may run while an upload is suspended. Retain the first
        // offer until its acknowledgement is consumed, rather than rebinding an
        // old ID-only callback to a later local edit. Ambiguity costs a retry.
        for item in pending where offeredVersions[item.id] == nil {
            offeredVersions[item.id] = versions[item.id]
        }
        return pending.map { $0.toSyncable() }
    }

    public func didReceiveRemoteEntry(_ entry: SyncableHistoryEntry) async {
        let result = await performAndWait(.remote(iOSHistoryItem.fromSyncable(entry)))
        for id in result.remoteAcknowledgedIDs {
            if let version = result.versions[id] {
                remotePendingVersions[id] = max(remotePendingVersions[id] ?? 0, version)
            }
        }
        for id in result.remoteNewerLocalIDs where versions[id] == result.versions[id]
            && (latestMutation[id] ?? 0) <= result.revision { syncedIDs.remove(id) }
        remoteRevision = max(remoteRevision, result.revision)
        scheduleRemoteCommit()
    }

    public func didDeleteRemoteEntry(id: UUID) async {
        let result = await performAndWait(.remoteDelete(id))
        syncedIDs.remove(id)
        if result.durable { saveSyncedIDs() }
        if !result.durable { remoteRevision = max(remoteRevision, result.revision) }
        if ownsDeletion(id, result: result) {
            TranscriptHandoffPublisher.invalidateIfAdvertising(entryID: id)
        }
    }

    public func didAcknowledgeSyncedEntries(ids: Set<UUID>) async {
        let offered = offeredVersions.filter { ids.contains($0.key) && directUploads[$0.key, default: 0] == 0 }
        guard await commitRemoteChangesAndWait() else { return }
        for (id, version) in offered where directUploads[id, default: 0] == 0 && offeredVersions[id] == version {
            offeredVersions.removeValue(forKey: id)
            if isCurrent(id, version: version, receiptRevision: publishedRevision) { syncedIDs.insert(id) }
        }
        pruneStaleSyncedIDs()
        saveSyncedIDs()
    }
}
#endif
