import Foundation
import SpeakCore

/// Owns the downloaded local runtimes and models of one desktop host.
///
/// Every mutation of a package (download, import, uninstall, refresh and
/// cleanup) holds that package's reservation for its whole duration,
/// including while it awaits blocking work on a dedicated thread. Nothing can
/// therefore delete another operation's staging or download. Each operation
/// first rediscovers the durable `active.json` state, and cleanup re-reads
/// that pointer itself, so a store that has not discovered a persisted
/// installation can never remove it. Versions are immutable; a replacement is
/// promoted only after complete verification, and an old version is removed
/// only once no lease uses it. State updates carry a generation, so late
/// progress from finished, cancelled or superseded work is never published.
public actor LocalModelStore {
    public typealias StateObserver = @Sendable (String, LocalModelInstallState) -> Void

    private enum Kind { case download, archiveImport, folderImport }

    private struct Operation {
        let kind: Kind
        let cancellation: LocalModelCancellation
        let task: Task<LocalModelInstallation, Error>
    }

    typealias Step = @Sendable (
        LocalModelStoreOperations, LocalModelCancellation, @escaping @Sendable (LocalModelInstallState) -> Void
    ) async throws -> LocalModelInstallation

    let operations: LocalModelStoreOperations
    private let transport: LocalModelDownloadTransport
    private let observer: StateObserver
    private var states: [String: LocalModelInstallState] = [:]
    private var generations: [String: UInt64] = [:]
    private var running: [String: Operation] = [:]
    private var installations: [String: LocalModelInstallation] = [:]
    private var leaseCounts: [String: [String: Int]] = [:]
    private var reserved: Set<String> = []
    private var reservationWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var refreshing: [String: Task<LocalModelInstallState, Never>] = [:]
    private var cleanupQueued: Set<String> = []
    private var uninstalling: Set<String> = []

    public init(
        root: URL, fileSystem: LocalModelFileSystem, digests: LocalModelDigestProvider,
        decompressor: LocalModelArchiveDecompressor, transport: LocalModelDownloadTransport,
        observer: @escaping StateObserver = { _, _ in }
    ) {
        self.init(
            operations: LocalModelStoreOperations(
                root: root, fileSystem: fileSystem, digests: digests, decompressor: decompressor
            ),
            transport: transport, observer: observer
        )
    }

    init(operations: LocalModelStoreOperations, transport: LocalModelDownloadTransport, observer: @escaping StateObserver) {
        self.operations = operations
        self.transport = transport
        self.observer = observer
    }

    public func state(of package: LocalModelPackage) -> LocalModelInstallState {
        states[package.identifier] ?? .notInstalled
    }

    /// The installation discovered or produced by this store, if any.
    public func installation(of package: LocalModelPackage) -> LocalModelInstallation? {
        installations[package.identifier]
    }

    /// Rediscovers the durable installation and removes leftovers of
    /// interrupted work. Concurrent calls share one refresh.
    @discardableResult
    public func refresh(_ package: LocalModelPackage) async -> LocalModelInstallState {
        if let pending = refreshing[package.identifier] { return await pending.value }
        let task = Task { await self.performRefresh(package) }
        refreshing[package.identifier] = task
        let state = await task.value
        if refreshing[package.identifier] == task { refreshing[package.identifier] = nil }
        return state
    }

    /// Downloads, verifies and installs the pinned archive, or joins the
    /// download already requested for this package.
    public func install(_ package: LocalModelPackage) async throws -> LocalModelInstallation {
        if let current = running[package.identifier] {
            guard current.kind == .download else { throw LocalModelStoreError.busy }
            return try await current.task.value
        }
        let transport = transport
        return try await begin(package, kind: .download) { operations, cancellation, progress in
            try await LocalModelDownloadStep(operations: operations, transport: transport)
                .run(package, cancellation: cancellation, progress: progress)
        }
    }

    /// Installs from a local copy of the exact pinned archive.
    public func importArchive(_ package: LocalModelPackage, from url: URL) async throws -> LocalModelInstallation {
        guard running[package.identifier] == nil else { throw LocalModelStoreError.busy }
        return try await begin(package, kind: .archiveImport) { operations, cancellation, progress in
            try await LocalModelBlockingWork.run(name: "Local model import") {
                try operations.installArchive(
                    at: url, package: package, origin: .archiveImport, cancellation: cancellation, progress: progress
                )
            }
        }
    }

    /// Installs from a folder holding the extracted pinned model files.
    public func importFolder(_ package: LocalModelPackage, from url: URL) async throws -> LocalModelInstallation {
        guard running[package.identifier] == nil else { throw LocalModelStoreError.busy }
        return try await begin(package, kind: .folderImport) { operations, cancellation, progress in
            progress(.verifying)
            return try await LocalModelBlockingWork.run(name: "Local model folder import") {
                try operations.installFolder(at: url, package: package, cancellation: cancellation)
            }
        }
    }

    /// Requests cancellation. Queued work never starts; running work stops at
    /// its next checkpoint and removes only its own staging. Once a
    /// replacement has claimed its commit point, it completes instead.
    public func cancel(_ package: LocalModelPackage) {
        guard let operation = running[package.identifier] else { return }
        if operation.cancellation.cancel() { operation.task.cancel() }
    }

    /// Removes every installed version. Refused while a download or import
    /// is requested or any lease is held, so running transcription keeps its
    /// files; later work waits until removal has finished.
    public func uninstall(_ package: LocalModelPackage) async throws {
        let identifier = package.identifier
        guard running[identifier] == nil else { throw LocalModelStoreError.busy }
        await reserve(identifier)
        defer { unreserve(identifier) }
        guard (leaseCounts[identifier] ?? [:]).isEmpty else { throw LocalModelStoreError.inUse }
        uninstalling.insert(identifier)
        defer { uninstalling.remove(identifier) }
        let generation = nextGeneration(package)
        let operations = operations
        do {
            try await LocalModelBlockingWork.run(name: "Local model removal") {
                try operations.uninstall(package, keeping: [])
            }
        } catch {
            _ = await discover(package)
            publishDiscovered(package, generation: generation)
            throw error
        }
        installations[identifier] = nil
        publish(package, .notInstalled, generation: generation)
    }

    /// Keeps the active installation's files for the lease's lifetime.
    public func lease(_ package: LocalModelPackage) async throws -> LocalModelLease {
        let identifier = package.identifier
        if installations[identifier] == nil { await refresh(package) }
        guard !uninstalling.contains(identifier), let installation = installations[identifier] else {
            throw LocalModelStoreError.notInstalled
        }
        leaseCounts[identifier, default: [:]][installation.version, default: 0] += 1
        return LocalModelLease(installation: installation) { [weak self] in
            Task { await self?.release(package, version: installation.version) }
        }
    }

    public func leasedVersions(_ package: LocalModelPackage) -> Set<String> {
        Set((leaseCounts[package.identifier] ?? [:]).keys)
    }

    // MARK: - Operations

    private func begin(_ package: LocalModelPackage, kind: Kind, step: @escaping Step) async throws
        -> LocalModelInstallation {
        let cancellation = LocalModelCancellation()
        let task = Task { try await self.perform(package, cancellation: cancellation, step: step) }
        running[package.identifier] = Operation(kind: kind, cancellation: cancellation, task: task)
        return try await task.value
    }

    private func perform(
        _ package: LocalModelPackage, cancellation: LocalModelCancellation, step: Step
    ) async throws -> LocalModelInstallation {
        let identifier = package.identifier
        await reserve(identifier)
        defer { unreserve(identifier) }
        _ = await discover(package)
        let previous = installations[identifier]
        var result: Result<LocalModelInstallation, Error> = .failure(CancellationError())
        if !cancellation.isCancelled {
            let generation = nextGeneration(package)
            let total = package.archive.byteCount
            publish(package, running[identifier]?.kind == .download
                ? .downloading(received: 0, total: total) : .verifying, generation: generation)
            let progress: @Sendable (LocalModelInstallState) -> Void = { [weak self] state in
                Task { await self?.publish(package, state, generation: generation) }
            }
            do { result = .success(try await step(operations, cancellation, progress)) } catch { result = .failure(error) }
        }
        if running[identifier]?.cancellation === cancellation { running[identifier] = nil }
        let settled = nextGeneration(package)
        switch result {
        case .success(let installation):
            installations[identifier] = installation
            publish(package, .installed(installation.receipt), generation: settled)
        case .failure(let error):
            let cancelled = error is CancellationError || cancellation.isCancelled
            let fallback: LocalModelInstallState = previous.map { .installed($0.receipt) } ?? .notInstalled
            publish(package, cancelled || previous != nil ? fallback : .failed(error.localizedDescription),
                    generation: settled)
        }
        await removeUnreferencedHoldingReservation(package)
        return try result.get()
    }

    private func performRefresh(_ package: LocalModelPackage) async -> LocalModelInstallState {
        let identifier = package.identifier
        await reserve(identifier)
        defer { unreserve(identifier) }
        let generation = nextGeneration(package)
        _ = await discover(package)
        publishDiscovered(package, generation: generation)
        await removeUnreferencedHoldingReservation(package)
        return state(of: package)
    }

    /// Reads the durable pointer and receipt on a worker thread. Requires
    /// the package reservation.
    private func discover(_ package: LocalModelPackage) async -> Result<LocalModelInstallation?, Error> {
        let operations = operations
        do {
            let found = try await LocalModelBlockingWork.run(name: "Local model discovery") {
                try operations.activeInstallation(package)
            }
            installations[package.identifier] = found
            return .success(found)
        } catch {
            installations[package.identifier] = nil
            return .failure(error)
        }
    }

    private func publishDiscovered(_ package: LocalModelPackage, generation: UInt64) {
        if let installation = installations[package.identifier] {
            publish(package, .installed(installation.receipt), generation: generation)
            return
        }
        switch operations.durablePointer(package) {
        case .absent: publish(package, .notInstalled, generation: generation)
        case .version, .unreadable:
            publish(package, .failed(LocalModelStoreError.corruptRecord.localizedDescription), generation: generation)
        }
    }

    private func removeUnreferencedHoldingReservation(_ package: LocalModelPackage) async {
        var keep = leasedVersions(package)
        if let active = installations[package.identifier]?.version { keep.insert(active) }
        let operations = operations
        try? await LocalModelBlockingWork.run(name: "Local model cleanup") {
            try operations.removeUnreferenced(package, keeping: keep)
        }
    }

    private func release(_ package: LocalModelPackage, version: String) {
        let identifier = package.identifier
        var counts = leaseCounts[identifier] ?? [:]
        let remaining = (counts[version] ?? 1) - 1
        counts[version] = remaining > 0 ? remaining : nil
        leaseCounts[identifier] = counts.isEmpty ? nil : counts
        guard remaining <= 0, version != installations[identifier]?.version,
              cleanupQueued.insert(identifier).inserted else { return }
        Task { await self.runQueuedCleanup(package) }
    }

    private func runQueuedCleanup(_ package: LocalModelPackage) async {
        await reserve(package.identifier)
        defer { unreserve(package.identifier) }
        cleanupQueued.remove(package.identifier)
        await removeUnreferencedHoldingReservation(package)
    }

    // MARK: - Reservation and publication

    private func reserve(_ identifier: String) async {
        guard reserved.contains(identifier) else {
            reserved.insert(identifier)
            return
        }
        // The releasing operation hands its reservation directly to us.
        await withCheckedContinuation { reservationWaiters[identifier, default: []].append($0) }
    }

    private func unreserve(_ identifier: String) {
        guard var waiters = reservationWaiters[identifier], !waiters.isEmpty else {
            reserved.remove(identifier)
            return
        }
        let next = waiters.removeFirst()
        reservationWaiters[identifier] = waiters.isEmpty ? nil : waiters
        next.resume()
    }

    private func nextGeneration(_ package: LocalModelPackage) -> UInt64 {
        let next = (generations[package.identifier] ?? 0) + 1
        generations[package.identifier] = next
        return next
    }

    private func publish(_ package: LocalModelPackage, _ state: LocalModelInstallState, generation: UInt64) {
        guard generations[package.identifier] == generation else { return }
        states[package.identifier] = state
        observer(package.identifier, state)
    }
}

/// Keeps one installed version's files for as long as it is held. Release is
/// idempotent and also happens on deinitialisation.
public final class LocalModelLease: @unchecked Sendable {
    public let installation: LocalModelInstallation
    private let onRelease: @Sendable () -> Void
    private let lock = NSLock()
    private var released = false

    init(installation: LocalModelInstallation, onRelease: @escaping @Sendable () -> Void) {
        self.installation = installation
        self.onRelease = onRelease
    }

    deinit { release() }

    public func release() {
        let first = lock.withLock { () -> Bool in
            defer { released = true }
            return !released
        }
        if first { onRelease() }
    }
}
