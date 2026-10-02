import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension SonioxLiveClient {
    /// Short, explicit bounds for tests that run in real time.
    struct Timing: Sendable {
        /// Drain, `finalize`, end-of-stream and the `finished` response.
        let overall: TimeInterval
        /// The handshake and each send, the configuration frame included.
        var startup: TimeInterval = 8
    }

    /// Test seam: real-time scheduling with the given bounds.
    convenience init(
        apiKey: String,
        model: String = "stt-rt-v5",
        language: String? = nil,
        sampleRate: Int = 16_000,
        timing: Timing,
        socketFactory: @escaping ConnectionFactory
    ) {
        self.init(
            apiKey: apiKey, model: model, language: language, sampleRate: sampleRate,
            makeConnection: socketFactory, finishTimeout: timing.overall
        )
        sendTimeout = timing.startup
        readyTimeout = timing.startup
    }
}
