import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore

/// The same generated protocol/capture scenario on Apple, WinHTTP and NIO.
/// Tests supply only the native transport; production requests are redirected
/// without altering their provider path, query, credentials or setup.
public final class AdditionalProviderLoopback: @unchecked Sendable {
    public enum Provider: String, CaseIterable, Sendable {
        case gemini, meta, modulate, grok
        public var sampleRate: Int { self == .meta || self == .grok ? 24_000 : 16_000 }
        public var expectedTranscript: String { self == .grok ? "Tail." : "Before. Tail." }
    }

    public let client: any FinalizingStreamingTranscriptionClient
    private let provider: Provider
    private let lock = NSLock()
    private var failures: [Error] = []
    public var errors: [Error] { lock.withLock { failures } }

    public init(
        provider: Provider, port: Int, scenario: String,
        makeConnection: @escaping @Sendable (URLRequest) -> any StreamingWebSocketConnection
    ) {
        self.provider = provider
        let factory: @Sendable (URLRequest) -> any StreamingWebSocketConnection = { request in
            var components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                ?? URLComponents()
            components.scheme = "ws"
            components.host = "127.0.0.1"
            components.port = port
            var local = request
            local.url = components.url
            local.setValue("local-only", forHTTPHeaderField: "X-JSTI-Probe")
            local.setValue("jsti-probe", forHTTPHeaderField: "Sec-WebSocket-Protocol")
            local.setValue(provider.rawValue, forHTTPHeaderField: "X-JSTI-Provider")
            local.setValue(scenario, forHTTPHeaderField: "X-JSTI-Provider-Scenario")
            return makeConnection(local)
        }
        let key = "synthetic-loopback-key"
        switch provider {
        case .gemini: client = GeminiLiveClient(apiKey: key, makeConnection: factory)
        case .meta: client = MetaMuseLiveClient(apiKey: key, makeConnection: factory)
        case .modulate: client = ModulateLiveClient(apiKey: key, makeConnection: factory)
        case .grok: client = XAILiveClient(apiKey: key, makeConnection: factory)
        }
    }

    public func start(onHeard: @escaping @Sendable () -> Void) {
        client.start(onTranscript: { text, _ in if text == "Before." { onHeard() } },
                     onError: { [weak self] error in
                         guard let self else { return }
                         self.lock.withLock { self.failures.append(error) }
                     })
        for index in 0..<3 {
            let bytes = provider.sampleRate / 5
            client.sendAudio(Data((0..<bytes).map { UInt8(truncatingIfNeeded: index * 31 + $0 * 7) }))
        }
    }
}
