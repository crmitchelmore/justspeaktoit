import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CleanupModelDiscoveryState: Sendable {
    public internal(set) var enabled = false
    public internal(set) var models: [DiscoveredCleanupModel] = []
    public internal(set) var isRefreshing = false
    public internal(set) var lastUpdated: Date?
    public internal(set) var errorMessage: String?
}

/// Metadata-only opt-in discovery. Initialization reads a bounded cache, never the network.
public final class CleanupModelDiscoveryStore: @unchecked Sendable {
    public static let shared = CleanupModelDiscoveryStore()
    public static let cacheLifetime: TimeInterval = 6 * 60 * 60
    public static let maximumCacheAge: TimeInterval = 7 * 24 * 60 * 60
    static let maximumBytes = 4 * 1024 * 1024
    private static let cacheLock = NSLock()
    public static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("JustSpeakToIt/CleanupModelDiscovery.json")
    }

    private let lock = NSLock()
    private let session: URLSession
    private let cacheURL: URL?
    private let clock: @Sendable () -> Date
    private var state = CleanupModelDiscoveryState()
    private var active: (id: UUID, task: Task<[DiscoveredCleanupModel], Error>)?
    private var lastAttempt: Date?
    private var deadline: Duration = .seconds(20)
    var timeout: Duration {
        get { lock.withLock { deadline } }
        set { lock.withLock { deadline = newValue } }
    }

    public init(session: URLSession? = nil, cacheURL: URL? = CleanupModelDiscoveryStore.defaultCacheURL,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration)
        self.cacheURL = cacheURL
        self.clock = clock
        if let cached = Self.read(cacheURL), cached.updatedAt <= clock(),
           clock().timeIntervalSince(cached.updatedAt) <= Self.maximumCacheAge {
            state.models = cached.models
            state.lastUpdated = cached.updatedAt
        }
    }

    public var snapshot: CleanupModelDiscoveryState { lock.withLock { state } }

    public func setEnabled(_ enabled: Bool) {
        let cancelled = lock.withLock { () -> Task<[DiscoveredCleanupModel], Error>? in
            state.enabled = enabled
            guard !enabled else { return nil }
            let previous = active?.task
            active = nil
            state.isRefreshing = false
            state.errorMessage = nil
            return previous
        }
        cancelled?.cancel()
    }

    /// Fresh discovered models that do not collide with a bundled entry, regardless of the opt-in.
    public func discoveredModels(_ state: CleanupModelDiscoveryState? = nil) -> [DiscoveredCleanupModel] {
        let state = state ?? snapshot
        guard let updated = state.lastUpdated,
              clock().timeIntervalSince(updated) <= Self.maximumCacheAge else { return [] }
        let bundled = Set(ModelCatalog.cloudPostProcessing.map(\.id))
        return state.models.filter { !bundled.contains($0.id) && CleanupModelRemovals.removal(for: $0.id) == nil }
    }

    /// Bundled entries win metadata collisions; saved discoveries stay visible even offline or disabled.
    public func options(selected: String? = nil) -> [ModelCatalog.Option] {
        let state = snapshot
        var result = ModelCatalog.cloudPostProcessing
        if state.enabled { result += discoveredModels(state).map(\.option) }
        if let selected, !result.contains(where: { $0.id == selected }),
           let retained = CleanupModelSelection.retainedOption(selected) { result.append(retained) }
        return result
    }

    /// At most one request, with a one-minute retry floor (including manual refresh).
    @discardableResult
    public func refresh(force: Bool = false) async -> CleanupModelDiscoveryState {
        guard !Task.isCancelled else { return snapshot }
        let started = clock()
        let operation = lock.withLock { () -> (UUID, Task<[DiscoveredCleanupModel], Error>)? in
            guard state.enabled, active == nil,
                  lastAttempt.map({ started.timeIntervalSince($0) >= 60 }) ?? true,
                  force || (state.lastUpdated.map({ started.timeIntervalSince($0) >= Self.cacheLifetime }) ?? true)
            else { return nil }
            let session = session
            let timeout = deadline
            let id = UUID()
            let task = Task.detached { try await Self.load(session: session, timeout: timeout) }
            active = (id, task)
            lastAttempt = started
            state.isRefreshing = true
            state.errorMessage = nil
            return (id, task)
        }
        guard let (id, task) = operation else { return snapshot }
        let outcome: Result<[DiscoveredCleanupModel], Error>
        do {
            let models = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            outcome = .success(models)
        } catch { outcome = .failure(error) }
        lock.withLock {
            guard active?.id == id, state.enabled else { return }
            active = nil
            state.isRefreshing = false
            switch outcome {
            case .success(let models):
                state.models = models
                let updatedAt = clock()
                state.lastUpdated = updatedAt
                // Write under the state lock so disabling cannot be overtaken by a late success.
                Self.write(.init(version: 1, updatedAt: updatedAt, models: models),
                           to: cacheURL, started: started)
            case .failure(let error):
                if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                    state.errorMessage = "Discovery unavailable. Bundled models and your saved selection are kept."
                }
            }
        }
        return snapshot
    }

    static func load(session: URLSession, timeout: Duration) async throws -> [DiscoveredCleanupModel] {
        var request = URLRequest(url: OpenRouterService.baseURL.appendingPathComponent("models"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let response = try await OpenRouterBoundedResponseTransport.perform(
            request, session: session, limit: maximumBytes, deadline: timeout
        ) { http in
            guard http.statusCode == 200 else { throw CleanupModelDiscoveryError.httpStatus(http.statusCode) }
        }
        try Task.checkCancellation()
        return try JSONDecoder().decode(CleanupModelResponse.self, from: response.body).data
    }

    private struct Cache: Codable {
        let version: Int
        let updatedAt: Date
        let models: [DiscoveredCleanupModel]
    }
    private static func read(_ url: URL?) -> Cache? {
        guard let url, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes,
              let cached = try? JSONDecoder().decode(Cache.self, from: data), cached.version == 1,
              cached.models.count <= 256, cached.models.allSatisfy(\.isValid),
              Set(cached.models.map(\.id)).count == cached.models.count else { return nil }
        return cached
    }
    private static func write(_ cache: Cache, to url: URL?, started: Date) {
        cacheLock.withLock {
            guard let url, read(url).map({ $0.updatedAt <= started }) ?? true,
                  let data = try? JSONEncoder().encode(cache), data.count <= maximumBytes else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                       withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch { /* In-memory metadata is still usable; no secret or provider error body is persisted. */ }
        }
    }
}
