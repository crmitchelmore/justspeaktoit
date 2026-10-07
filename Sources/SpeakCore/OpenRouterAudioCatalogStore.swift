import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Discovery state shared by native hosts without requiring a UI actor or run loop.
public struct OpenRouterAudioCatalogState: Sendable {
    public internal(set) var models: [OpenRouterAudioModel] = []
    public internal(set) var isRefreshing = false
    public internal(set) var lastUpdated: Date?
    public internal(set) var errorMessage: String?
    /// Monotonic within this store instance; ignore older asynchronous UI updates.
    public internal(set) var revision: UInt64 = 0

    public func models(for capability: OpenRouterAudioCapability) -> [OpenRouterAudioModel] {
        models.filter { $0.supports(capability) }
    }
}

/// One refresh/cache state machine for the Apple observation facade and other hosts.
/// Mutable state is protected by a lock; network work always runs in a detached task.
/// Constructing the store reads the bounded disk cache synchronously, never the network.
public final class OpenRouterAudioCatalogStore: @unchecked Sendable {
    public static let cacheLifetime: TimeInterval = 6 * 60 * 60
    public static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("JustSpeakToIt/OpenRouterAudioCatalog.json")
    }

    private let lock = NSLock()
    private let apiKeyProvider: @Sendable () async -> String?
    private let session: URLSession
    private let cacheURL: URL?
    private let clock: @Sendable () -> Date
    private var state = OpenRouterAudioCatalogState()
    private var active: Refresh?
    private var timeout: Duration = .seconds(30)

    private struct Refresh {
        let id: UUID
        let order: OpenRouterAudioCatalogRequestOrder
        let task: Task<[OpenRouterAudioModel], Error>
    }

    private struct StartedRefresh {
        let refresh: Refresh
        let state: OpenRouterAudioCatalogState
        let previous: Task<[OpenRouterAudioModel], Error>?
    }

    public init(
        apiKeyProvider: @escaping @Sendable () async -> String? = { nil },
        session: URLSession = .shared,
        cacheURL: URL? = OpenRouterAudioCatalogStore.defaultCacheURL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session
        self.cacheURL = cacheURL
        self.clock = clock
        if let cached = OpenRouterAudioCatalogSnapshot.read(from: cacheURL, now: clock()) {
            state.models = cached.models
            state.lastUpdated = cached.updatedAt
        }
    }

    public var snapshot: OpenRouterAudioCatalogState { lock.withLock { state } }
    public var isStale: Bool { lock.withLock { stale(at: clock()) } }

    var refreshTimeout: Duration {
        get { lock.withLock { timeout } }
        set { lock.withLock { timeout = newValue } }
    }

    /// Refresh from any executor. A forced request supersedes the previous one.
    /// Optional observations carry a revision so a facade can ignore delayed delivery.
    /// The returned snapshot is also available immediately through `snapshot`.
    @discardableResult
    public func refresh(
        force: Bool = false,
        onChange: (@Sendable (OpenRouterAudioCatalogState) async -> Void)? = nil
    ) async -> OpenRouterAudioCatalogState {
        guard !Task.isCancelled, let (refresh, started) = begin(force: force) else { return snapshot }
        if let onChange { await onChange(started) }
        let outcome: Result<[OpenRouterAudioModel], Error>
        do {
            let models = try await withTaskCancellationHandler {
                try await refresh.task.value
            } onCancel: {
                refresh.task.cancel()
            }
            try Task.checkCancellation()
            outcome = .success(models)
        } catch {
            outcome = .failure(error)
        }
        let completed = finish(refresh, outcome: outcome, cancelled: Task.isCancelled)
        if let onChange { await onChange(completed) }
        return completed
    }

    private func stale(at date: Date) -> Bool {
        guard let lastUpdated = state.lastUpdated else { return true }
        return date.timeIntervalSince(lastUpdated) >= Self.cacheLifetime
    }

    private func begin(force: Bool) -> (Refresh, OpenRouterAudioCatalogState)? {
        let result: StartedRefresh? = lock.withLock {
            guard force || (!state.isRefreshing && stale(at: clock())) else { return nil }
            let previous = active?.task
            let provider = apiKeyProvider
            let session = session
            let timeout = timeout
            let refresh = Refresh(
                id: UUID(), order: OpenRouterAudioCatalogRequestOrder.begin(at: clock()),
                task: Task.detached(priority: .utility) {
                    let key = await provider()
                    try Task.checkCancellation()
                    return try await OpenRouterAudioCatalogLoader.load(apiKey: key, session: session, timeout: timeout)
                }
            )
            active = refresh
            state.isRefreshing = true
            state.errorMessage = nil
            state.revision &+= 1
            return StartedRefresh(refresh: refresh, state: state, previous: previous)
        }
        guard let result else { return nil }
        // Cancellation handlers may call back into the store; never invoke them
        // while holding its state lock.
        result.previous?.cancel()
        return (result.refresh, result.state)
    }

    private func finish(
        _ refresh: Refresh, outcome: Result<[OpenRouterAudioModel], Error>, cancelled: Bool
    ) -> OpenRouterAudioCatalogState {
        var persisted: OpenRouterAudioCatalogSnapshot?
        let completed = lock.withLock {
            guard active?.id == refresh.id else { return state }
            active = nil
            state.isRefreshing = false
            state.revision &+= 1
            guard !cancelled else { return state }
            switch outcome {
            case .success(let models):
                let updatedAt = clock()
                state.models = models
                state.lastUpdated = updatedAt
                persisted = OpenRouterAudioCatalogSnapshot(
                    version: 1, updatedAt: updatedAt, models: models, requestOrder: refresh.order
                )
            case .failure(let error):
                guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return state }
                state.errorMessage = (error as? OpenRouterAudioCatalogError)?.errorDescription
                    ?? "Could not refresh OpenRouter audio models. Check your connection and try again."
            }
            return state
        }
        // Atomic compare/write has its own canonical cross-consumer lock. Keep
        // disk latency outside this store's state lock and retain request order.
        persisted?.write(to: cacheURL)
        return completed
    }
}
