#if canImport(Combine)
import Combine
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Combine)
/// Apple hosts observe the catalogue through Combine, exactly as before.
public typealias OpenRouterAudioCatalogObservation = ObservableObject
#else
/// Hosts without Combine observe the catalogue through `onChange`.
public protocol OpenRouterAudioCatalogObservation: AnyObject {}
#endif

/// Refreshable shared discovery for OpenRouter's dedicated speech and transcription endpoints.
@MainActor
public final class OpenRouterAudioCatalog: OpenRouterAudioCatalogObservation {
    #if canImport(Combine)
    @Published public private(set) var models: [OpenRouterAudioModel] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastUpdated: Date?
    @Published public private(set) var errorMessage: String?
    #else
    public private(set) var models: [OpenRouterAudioModel] = [] { didSet { onChange?() } }
    public private(set) var isRefreshing = false { didSet { onChange?() } }
    public private(set) var lastUpdated: Date? { didSet { onChange?() } }
    public private(set) var errorMessage: String? { didSet { onChange?() } }
    /// Called on the main actor after any of the published properties changes.
    public var onChange: (@MainActor () -> Void)?
    #endif

    public static let cacheLifetime = OpenRouterAudioCatalogStore.cacheLifetime
    nonisolated public static var defaultCacheURL: URL? { OpenRouterAudioCatalogStore.defaultCacheURL }

    public var isStale: Bool { store.isStale }

    private let store: OpenRouterAudioCatalogStore
    private var revision: UInt64 = 0
    // Preserve the existing internal test seam without duplicating refresh policy.
    var refreshTimeout: Duration {
        get { store.refreshTimeout }
        set { store.refreshTimeout = newValue }
    }

    public init(
        apiKeyProvider: @escaping @Sendable () async -> String? = { nil },
        session: URLSession = .shared,
        cacheURL: URL? = OpenRouterAudioCatalog.defaultCacheURL,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        store = OpenRouterAudioCatalogStore(
            apiKeyProvider: apiKeyProvider, session: session, cacheURL: cacheURL, clock: clock
        )
        apply(store.snapshot)
    }

    public func models(for capability: OpenRouterAudioCapability) -> [OpenRouterAudioModel] {
        models.filter { $0.supports(capability) }
    }

    /// The shared store owns supersession, cancellation and disk ordering.
    public func refresh(force: Bool = false) async {
        await store.refresh(force: force) { [weak self] state in
            await self?.apply(state)
        }
    }

    private func apply(_ state: OpenRouterAudioCatalogState) {
        guard state.revision >= revision else { return }
        revision = state.revision
        models = state.models
        isRefreshing = state.isRefreshing
        lastUpdated = state.lastUpdated
        errorMessage = state.errorMessage
    }
}
