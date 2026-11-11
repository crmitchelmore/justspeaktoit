import CloudKit
import Foundation

/// Seam over `CKFetchRecordZoneChangesOperation` so lifecycle code can cancel an
/// in-flight fetch and tests can inject an operation that models cancellation.
protocol KeySyncFetchOperationRunning: AnyObject, Sendable {
    /// Starts the operation. `completion` fires at most once when the fetch
    /// finishes; late or repeated invocations are ignored by the caller's gate.
    func run(completion: @escaping @Sendable (Result<Void, Error>) -> Void)
    /// Requests prompt teardown of the underlying operation.
    func cancel()
}

/// One-shot gate that resumes a fetch continuation exactly once even when
/// cancellation and CloudKit completion race each other.
final class KeySyncFetchCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?
    private var isFinished = false

    /// Registers the continuation. Returns `true` while the fetch is still
    /// pending; returns `false` when the gate already finished (the
    /// continuation is resumed immediately and the operation must not start).
    func register(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        let immediateResult: Result<Void, Error>? = lock.withLock {
            if let pendingResult {
                self.pendingResult = nil
                return pendingResult
            }
            self.continuation = continuation
            return nil
        }
        if let immediateResult {
            continuation.resume(with: immediateResult)
            return false
        }
        return true
    }

    func finish(with result: Result<Void, Error>) {
        let waiting: CheckedContinuation<Void, Error>? = lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            if let continuation {
                self.continuation = nil
                return continuation
            }
            pendingResult = result
            return nil
        }
        waiting?.resume(with: result)
    }
}

final class LiveKeySyncFetchOperation: KeySyncFetchOperationRunning, @unchecked Sendable {
    private let operation: CKFetchRecordZoneChangesOperation
    private let database: CKDatabase

    init(operation: CKFetchRecordZoneChangesOperation, database: CKDatabase) {
        self.operation = operation
        self.database = database
    }

    func run(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        operation.fetchRecordZoneChangesResultBlock = { result in
            switch result {
            case .success:
                completion(.success(()))
            case .failure(let error):
                completion(.failure(error))
            }
        }
        database.add(operation)
    }

    func cancel() {
        operation.cancel()
    }
}

final class KeySyncFetchAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [CKRecord] = []
    private var deletedIDs: [CKRecord.ID] = []
    private var serverChangeToken: CKServerChangeToken?
    private var moreComing = false
    private var errors: [Error] = []

    func append(record: CKRecord) {
        lock.withLock { records.append(record) }
    }

    func appendDeletedID(_ recordID: CKRecord.ID) {
        lock.withLock { deletedIDs.append(recordID) }
    }

    func updateToken(_ token: CKServerChangeToken?) {
        guard let token else { return }
        lock.withLock { serverChangeToken = token }
    }

    func updateMoreComing(_ value: Bool) {
        lock.withLock { moreComing = value }
    }

    func append(error: Error) {
        lock.withLock { errors.append(error) }
    }

    func result() throws -> KeySyncFetchResult {
        let snapshot = lock.withLock {
            (
                errors.first,
                records,
                deletedIDs,
                serverChangeToken,
                moreComing
            )
        }
        if let error = snapshot.0 {
            throw error
        }
        let tokenData = try snapshot.3.map {
            try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
        }
        return KeySyncFetchResult(
            records: snapshot.1,
            deletedIDs: snapshot.2,
            serverChangeTokenData: tokenData,
            moreComing: snapshot.4
        )
    }
}
