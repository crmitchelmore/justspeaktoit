import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension GladiaLiveClient {
    /// Explicit framed/staged mode. Existing constructors remain legacy.
    public convenience init(
        apiKey: String, model: String = "solaria-1", language: String? = nil,
        sampleRate: Int = 16_000, session: URLSession = .shared, options: LiveClientOptions
    ) {
        self.init(
            apiKey: apiKey, model: model, language: language, sampleRate: sampleRate,
            baseURL: GladiaLive.baseURL, initiateSession: Self.sessionInitiator(session: session),
            makeConnection: { URLSessionStreamingConnection(session: session, request: $0) },
            schedule: Self.defaultScheduler, mode: .configured(GladiaConfiguredTiming(options: options)),
            usesCheckedDefaultScheduler: true
        )
    }

    /// Explicit options with held transports; scheduler is required so this
    /// overload cannot change any existing constructor's default scheduling.
    public convenience init(
        apiKey: String, model: String = GladiaLive.defaultModel, language: String? = nil,
        sampleRate: Int = 16_000, baseURL: URL = GladiaLive.baseURL, options: LiveClientOptions,
        initiateSession: @escaping SessionInitiator, makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler
    ) {
        self.init(
            apiKey: apiKey, model: model, language: language, sampleRate: sampleRate,
            baseURL: baseURL, initiateSession: initiateSession, makeConnection: makeConnection,
            schedule: schedule, mode: .configured(GladiaConfiguredTiming(options: options)),
            usesCheckedDefaultScheduler: false
        )
    }
}
