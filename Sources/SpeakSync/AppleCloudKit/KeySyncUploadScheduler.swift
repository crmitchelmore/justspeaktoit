import Foundation
import SpeakCore

/// What a debounced upload needs from the service that owns the sync lifecycle.
@MainActor
protocol KeySyncUploadHost: AnyObject {
    /// The local mutation still waiting for `identifier`, if any.
    func pendingMutation(for identifier: String) -> PendingKeySyncMutation?
    /// True while a full sync runs; a debounced upload waits for it to finish.
    var isFullSyncRunning: Bool { get }
    /// Uploads `mutation` for the sync `generation`. Returns false, without
    /// uploading, when no key or database is available.
    func uploadDebounced(_ mutation: PendingKeySyncMutation, generation: UInt64) async throws -> Bool
}

/// One debounced upload task per key, retried with capped exponential backoff
/// until its pending mutation is cleared, superseded or the work is suspended.
@MainActor
final class KeySyncUploadScheduler {
    private static let debounceNanoseconds: UInt64 = 750_000_000
    private static let initialRetryNanoseconds: UInt64 = 2_000_000_000
    private static let maximumRetryNanoseconds: UInt64 = 60_000_000_000

    private let sleep: (UInt64) async throws -> Void
    private let log = SpeakLogger.logger(category: "CloudKitKeySync")
    private var tasks: [String: Task<Void, Never>] = [:]
    private var taskIDs: [String: UUID] = [:]
    private var retryAttempts: [String: Int] = [:]

    init(sleep: @escaping (UInt64) async throws -> Void) {
        self.sleep = sleep
    }

    /// Starts the upload task for `identifier` unless one is running or nothing is pending.
    func schedule(identifier: String, generation: UInt64, host: KeySyncUploadHost) {
        guard tasks[identifier] == nil,
              host.pendingMutation(for: identifier) != nil else {
            return
        }

        let taskID = UUID()
        taskIDs[identifier] = taskID
        tasks[identifier] = Task { @MainActor [weak self, weak host] in
            defer {
                if self?.taskIDs[identifier] == taskID {
                    self?.tasks[identifier] = nil
                    self?.taskIDs[identifier] = nil
                    self?.retryAttempts[identifier] = nil
                }
            }
            while !Task.isCancelled {
                guard let self, let host,
                      await self.runAttempt(identifier: identifier, generation: generation, host: host) else {
                    return
                }
            }
        }
    }

    /// Cancels every upload task and forgets it, returning the tasks to await.
    func suspend() -> [Task<Void, Never>] {
        let suspended = Array(tasks.values)
        suspended.forEach { $0.cancel() }
        tasks.removeAll()
        taskIDs.removeAll()
        return suspended
    }

    func clearRetries() {
        retryAttempts.removeAll()
    }

    /// One debounce-then-upload pass. Returns true to run another pass.
    private func runAttempt(identifier: String, generation: UInt64, host: KeySyncUploadHost) async -> Bool {
        guard let observedMutation = host.pendingMutation(for: identifier) else {
            return false
        }
        do {
            try await sleep(Self.debounceNanoseconds)
        } catch {
            return false
        }
        guard host.pendingMutation(for: identifier)?.operationID == observedMutation.operationID,
              !host.isFullSyncRunning else {
            return true
        }

        do {
            guard try await host.uploadDebounced(observedMutation, generation: generation) else {
                return false
            }
            retryAttempts[identifier] = nil
        } catch is CancellationError {
            return false
        } catch {
            log.error("Debounced key upload failed for \(identifier): \(error.localizedDescription)")
            let attempt = (retryAttempts[identifier] ?? 0) + 1
            retryAttempts[identifier] = attempt
            do {
                try await sleep(Self.retryDelay(attempt: attempt))
            } catch {
                return false
            }
        }
        return host.pendingMutation(for: identifier) != nil
    }

    static func retryDelay(attempt: Int) -> UInt64 {
        let shift = UInt64(min(attempt - 1, 5))
        return min(initialRetryNanoseconds << shift, maximumRetryNanoseconds)
    }
}
