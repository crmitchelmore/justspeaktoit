import Combine
import Foundation

/// Refreshable shared discovery for OpenRouter's dedicated speech and transcription endpoints.
@MainActor
public final class OpenRouterAudioCatalog: ObservableObject {
    @Published public private(set) var models: [OpenRouterAudioModel] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var errorMessage: String?

    public static let cacheLifetime: TimeInterval = 6 * 60 * 60
    nonisolated public static var defaultCacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("JustSpeakToIt/OpenRouterAudioCatalog.json")
    }

    public var isStale: Bool {
        guard let lastUpdated else { return true }
        return clock().timeIntervalSince(lastUpdated) >= Self.cacheLifetime
    }

    private let apiKeyProvider: @Sendable () async -> String?
    private let session: URLSession
    private let cacheURL: URL?
    private let clock: @Sendable () -> Date
    private var refreshID: UUID?
    private var activeRefresh: Task<[OpenRouterAudioModel], Error>?
    // Internal override allows deadline/cancellation tests without long-running requests.
    var refreshTimeout: Duration = .seconds(30)

    public init(
        apiKeyProvider: @escaping @Sendable () async -> String? = { nil },
        session: URLSession = .shared,
        cacheURL: URL? = OpenRouterAudioCatalog.defaultCacheURL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session
        self.cacheURL = cacheURL
        self.clock = clock
        if let snapshot = OpenRouterAudioCatalogSnapshot.read(from: cacheURL, now: clock()) {
            models = snapshot.models
            lastUpdated = snapshot.updatedAt
        }
    }

    public func models(for capability: OpenRouterAudioCapability) -> [OpenRouterAudioModel] {
        models.filter { $0.supports(capability) }
    }

    /// A forced refresh supersedes an in-flight request; superseded or cancelled work cannot replace state or cache.
    public func refresh(force: Bool = false) async {
        guard !Task.isCancelled, force || (!isRefreshing && isStale) else { return }
        activeRefresh?.cancel()
        let identifier = UUID()
        let requestOrder = OpenRouterAudioCatalogRequestOrder.begin(at: clock())
        refreshID = identifier
        isRefreshing = true
        errorMessage = nil
        let provider = apiKeyProvider
        let session = session
        let timeout = refreshTimeout
        let task = Task.detached(priority: .utility) {
            let key = await provider()
            try Task.checkCancellation()
            return try await OpenRouterAudioCatalogLoader.load(apiKey: key, session: session, timeout: timeout)
        }
        activeRefresh = task
        defer {
            if refreshID == identifier {
                activeRefresh = nil
                refreshID = nil
                isRefreshing = false
            }
        }
        do {
            let fetched = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard refreshID == identifier else { return }
            let updatedAt = clock()
            models = fetched
            lastUpdated = updatedAt
            OpenRouterAudioCatalogSnapshot(
                version: 1, updatedAt: updatedAt, models: fetched, requestOrder: requestOrder
            ).write(to: cacheURL)
        } catch {
            guard refreshID == identifier, !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            errorMessage = (error as? OpenRouterAudioCatalogError)?.errorDescription
                ?? "Could not refresh OpenRouter audio models. Check your connection and try again."
        }
    }
}
