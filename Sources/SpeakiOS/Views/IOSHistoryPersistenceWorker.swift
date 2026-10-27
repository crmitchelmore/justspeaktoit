#if os(iOS)
import Foundation
import SpeakCore

/// Queue ownership is the isolation boundary, including legacy synchronous calls.
/// The queue never calls MainActor. Codable, hashing and StorageIO stay on it.
actor IOSHistoryPersistence {
    /// Injected closures are transferred to, and called only on, the worker.
    /// Test implementations must synchronize any state also accessed by the test.
    struct StorageIO: Sendable {
        var read: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
        var write: @Sendable (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        var remove: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    }

    enum Operation: Sendable {
        case load, retry, commit
        case upsert(iOSHistoryItem)
        case processed(UUID, String, String?)
        case error(UUID, String)
        case remove(UUID), clear
        case remote(iOSHistoryItem), remoteDelete(UUID)
    }

    struct Result: Sendable {
        let revision: UInt64
        let rows: [iOSHistoryItem]
        let versions: [UUID: UInt64]
        let durableVersions: [UUID: UInt64]
        let durable: Bool
        let isReady: Bool
        let errorMessage: String?
        let recoveredIDs: Set<UUID>
        let removedIDs: Set<UUID>
        let remoteAcknowledgedIDs: Set<UUID>
        let remoteNewerLocalIDs: Set<UUID>
    }

    /// A ticket is admitted synchronously before its caller suspends. Cancellation
    /// of that caller cannot revoke an admitted mutation or its durability receipt.
    final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result?
        private var waiters: [CheckedContinuation<Result, Never>] = []

        func wait() async -> Result {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        fileprivate func finish(_ value: Result) {
            lock.lock()
            result = value
            let continuations = waiters
            waiters.removeAll()
            lock.unlock()
            for continuation in continuations { continuation.resume(returning: value) }
        }
    }

    private nonisolated let worker: IOSHistoryPersistenceWorker

    init(fileURL: URL, storageIO: StorageIO = .init()) {
        worker = IOSHistoryPersistenceWorker(fileURL: fileURL, storageIO: storageIO)
    }

    nonisolated func admit(_ operation: Operation, revision: UInt64) -> Ticket {
        worker.admit(operation, revision: revision)
    }

    func result(for ticket: Ticket) async -> Result { await ticket.wait() }

    /// Compatibility only: blocks its caller until this same worker commits.
    nonisolated func synchronously(_ operation: Operation, revision: UInt64) -> Result {
        worker.synchronously(operation, revision: revision)
    }
}

/// Mutable state below is accessed exclusively on `queue`; unchecked conformance
/// transfers executor ownership, not an assertion that state is freely shareable.
private final class IOSHistoryPersistenceWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.justspeaktoit.ios.history-persistence", qos: .utility)
    private let fileURL: URL
    private let storageIO: IOSHistoryPersistence.StorageIO
    private lazy var state = IOSHistoryPersistenceState(fileURL: fileURL, storageIO: storageIO)
    private var rows: [iOSHistoryItem] = []
    private var attemptedLoad = false
    private var versions: [UUID: UInt64] = [:]
    private var durableVersions: [UUID: UInt64] = [:]

    init(fileURL: URL, storageIO: IOSHistoryPersistence.StorageIO) {
        self.fileURL = fileURL
        self.storageIO = storageIO
    }

    func admit(_ operation: IOSHistoryPersistence.Operation, revision: UInt64) -> IOSHistoryPersistence.Ticket {
        let ticket = IOSHistoryPersistence.Ticket()
        queue.async { ticket.finish(self.execute(operation, revision: revision)) }
        return ticket
    }

    func synchronously(
        _ operation: IOSHistoryPersistence.Operation, revision: UInt64
    ) -> IOSHistoryPersistence.Result {
        queue.sync { self.execute(operation, revision: revision) }
    }

    private func execute(
        _ operation: IOSHistoryPersistence.Operation, revision: UInt64
    ) -> IOSHistoryPersistence.Result {
        let previous = Dictionary(rows.map { ($0.id, $0.historyRecord) }, uniquingKeysWith: { _, last in last })
        let hadAttemptedLoad = attemptedLoad
        if !attemptedLoad {
            attemptedLoad = true
            rows = state.load(visible: rows)
        }
        let initiallyDurable = !hadAttemptedLoad && state.isReady
            ? Dictionary(rows.map { ($0.id, $0.historyRecord) }, uniquingKeysWith: { _, last in last }) : [:]
        let effects = apply(operation, hadAttemptedLoad: hadAttemptedLoad)
        let currentIDs = Set(rows.map(\.id))
        versions = versions.filter { currentIDs.contains($0.key) }
        for item in rows where previous[item.id] != item.historyRecord { versions[item.id] = revision }
        if effects.committedSnapshot {
            durableVersions = versions
        } else {
            for item in rows where initiallyDurable[item.id] == item.historyRecord {
                durableVersions[item.id] = versions[item.id]
            }
        }
        durableVersions = durableVersions.filter { currentIDs.contains($0.key) }
        return .init(
            revision: revision, rows: rows, versions: versions, durableVersions: durableVersions,
            durable: effects.durable, isReady: state.isReady, errorMessage: state.errorMessage,
            recoveredIDs: state.recoveredIDs, removedIDs: effects.removedIDs,
            remoteAcknowledgedIDs: effects.remoteAcknowledgedIDs, remoteNewerLocalIDs: effects.remoteNewerLocalIDs
        )
    }

    private struct Effects {
        var durable: Bool
        var committedSnapshot = false
        var removedIDs: Set<UUID> = []
        var remoteAcknowledgedIDs: Set<UUID> = []
        var remoteNewerLocalIDs: Set<UUID> = []
    }

    private func apply(_ operation: IOSHistoryPersistence.Operation, hadAttemptedLoad: Bool) -> Effects {
        switch operation {
        case .load, .retry, .commit:
            return maintenance(operation, hadAttemptedLoad: hadAttemptedLoad)
        case .upsert(let item):
            upsert(item)
            return saveSnapshot()
        case .processed, .error:
            return updateFields(operation)
        case .remove(let id):
            let (durable, removed) = remove([id])
            return Effects(durable: durable, committedSnapshot: durable, removedIDs: removed)
        case .clear:
            let (durable, removed) = remove(Set(rows.map(\.id)))
            return Effects(durable: durable, committedSnapshot: durable, removedIDs: removed)
        case .remote(let item): return receiveRemote(item)
        case .remoteDelete(let id):
            rows.removeAll { $0.id == id }
            state.rememberDeletion(id)
            var result = saveSnapshot()
            result.removedIDs = [id]
            return result
        }
    }

    private func maintenance(_ operation: IOSHistoryPersistence.Operation, hadAttemptedLoad: Bool) -> Effects {
        switch operation {
        case .load: return Effects(durable: state.isReady)
        case .retry:
            if hadAttemptedLoad && !state.isReady { rows = state.load(visible: rows) }
            return state.isReady ? saveSnapshot() : Effects(durable: false)
        case .commit:
            rows.sort { $0.createdAt > $1.createdAt }
            return saveSnapshot()
        default: preconditionFailure("Only maintenance operations enter this helper")
        }
    }

    private func updateFields(_ operation: IOSHistoryPersistence.Operation) -> Effects {
        switch operation {
        case let .processed(id, text, error):
            guard let item = rows.first(where: { $0.id == id }) else { return Effects(durable: state.isReady) }
            upsert(item.withPostProcessed(text).withError(error))
        case let .error(id, message):
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return Effects(durable: state.isReady) }
            rows[index] = rows[index].withError(message)
            state.remember(rows[index])
        default: preconditionFailure("Only row field operations enter this helper")
        }
        return saveSnapshot()
    }

    private func receiveRemote(_ item: iOSHistoryItem) -> Effects {
        if let index = rows.firstIndex(where: { $0.id == item.id }) {
            if item.updatedAt > rows[index].updatedAt {
                rows[index] = item
                state.remember(item)
            } else if item.updatedAt < rows[index].updatedAt {
                return Effects(durable: false, remoteNewerLocalIDs: [item.id])
            }
        } else {
            rows.insert(item, at: 0)
            state.remember(item)
        }
        // The debounced commit, not receipt of a remote row, owns its acknowledgement.
        return Effects(durable: false, remoteAcknowledgedIDs: [item.id])
    }

    private func saveSnapshot() -> Effects {
        let durable = state.save(rows)
        return Effects(durable: durable, committedSnapshot: durable)
    }

    private func upsert(_ item: iOSHistoryItem) {
        let current: iOSHistoryItem
        if let index = rows.firstIndex(where: { $0.id == item.id }) {
            current = rows[index].updatedAt > item.updatedAt ? rows[index] : item
            if rows[index].createdAt == current.createdAt { rows[index] = current } else {
                rows.remove(at: index)
                let insertion = rows.firstIndex { $0.createdAt < current.createdAt } ?? rows.endIndex
                rows.insert(current, at: insertion)
            }
        } else {
            current = item
            let insertion = rows.firstIndex { $0.createdAt < current.createdAt } ?? rows.endIndex
            rows.insert(current, at: insertion)
        }
        state.remember(current)
    }

    private func remove(_ ids: Set<UUID>) -> (Bool, Set<UUID>) {
        guard state.isReady else { return (false, []) }
        let previous = rows
        rows.removeAll { ids.contains($0.id) }
        guard state.saveDeleting(ids, items: rows) else {
            rows = previous
            return (false, [])
        }
        return (true, ids.intersection(Set(previous.map(\.id))))
    }
}
#endif
