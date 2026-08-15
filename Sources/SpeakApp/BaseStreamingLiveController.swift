import Foundation
import SpeakCore
import os.log

private final class OneShotStreamingResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ result: Bool) {
        lock.lock()
        let pendingContinuation = continuation
        self.continuation = nil
        lock.unlock()
        pendingContinuation?.resume(returning: result)
    }
}

// MARK: - BaseStreamingLiveController

/// Shared WebSocket lifecycle for cloud live-transcription providers.
///
/// Most cloud providers follow the same sequence:
/// 1. Open WebSocket with auth header + query params
/// 2. Stream 100ms PCM chunks (50-1000ms window, 100ms preferred)
/// 3. Receive interim/final transcripts
/// 4. On stop: flush pending PCM, await pending sends (bounded timeout),
///    send `ForceEndpoint`/`CloseStream`, then `Terminate`/close.
///
/// This base class encapsulates steps 1, 2 and 4 so concrete controllers
/// only implement provider-specific message encoding/decoding. It is
/// intentionally not adopted by existing controllers yet — new providers
/// should subclass it, and existing ones can migrate incrementally.
open class BaseStreamingLiveController: NSObject {
    let log: Logger
    private let providerID: String

    /// Pending PCM chunks waiting for WebSocket send completion.
    private var pendingAudioChunks: [Data] = []
    private let pendingQueue = DispatchQueue(label: "com.justspeaktoit.baseStreaming.pending")
    private var isStopping = false

    public init(providerID: String, logCategory: String) {
        self.providerID = providerID
        self.log = SpeakLogger.logger(category: logCategory)
        super.init()
    }

    // MARK: - Subclass hooks

    /// Provider-specific WebSocket URL. Called on `start`.
    open func streamingURL() -> URL {
        fatalError("Subclasses must override streamingURL()")
    }

    /// Provider-specific headers (auth, etc.).
    open func streamingHeaders(apiKey: String) -> [String: String] { [:] }

    /// Encode PCM chunk into provider wire format (e.g. base64 JSON, binary).
    open func encodeAudioChunk(_ data: Data) -> Data { data }

    /// Decode provider transcript message. Return (text, isFinal) or nil to ignore.
    open func decodeTranscriptMessage(_ data: Data) -> (String, Bool)? { nil }

    // MARK: - Shared lifecycle helpers

    /// Queues PCM chunk; flushed in order on stop. Subclasses call from `sendAudio`.
    public func enqueueAudioChunk(_ data: Data) {
        pendingQueue.sync { pendingAudioChunks.append(data) }
    }

    /// Flushes pending chunks via `send` closure with a hard caller-facing timeout.
    /// Returns false at the deadline even if a provider send ignores cancellation;
    /// that abandoned send may still finish in its unstructured task later.
    @discardableResult
    public func flushPendingChunks(
        send: @escaping @Sendable (Data) async throws -> Void,
        timeout: TimeInterval = 1.0
    ) async -> Bool {
        let chunks: [Data] = pendingQueue.sync {
            let copy = pendingAudioChunks
            pendingAudioChunks.removeAll()
            return copy
        }
        guard !chunks.isEmpty else { return true }
        guard timeout.isFinite, timeout > 0 else { return false }
        let maximumTimeout = TimeInterval(UInt64.max / 1_000_000_000)
        let timeoutNanoseconds = UInt64(min(timeout, maximumTimeout) * 1_000_000_000)
        let success = await withCheckedContinuation { continuation in
            let result = OneShotStreamingResult(continuation: continuation)
            Task {
                for chunk in chunks {
                    do {
                        try await send(chunk)
                    } catch {
                        result.resolve(false)
                        return
                    }
                }
                result.resolve(true)
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                result.resolve(false)
            }
        }
        log.debug(
            // swiftlint:disable:next line_length
            "\(self.providerID): flushed \(chunks.count) pending chunks — \(success ? "ok" : "timeout", privacy: .public)"
        )
        return success
    }

    /// Marks stopping state to prevent fallback/reconnect after `stop` begins.
    public func markStopping() {
        pendingQueue.sync { isStopping = true }
    }

    public var isCurrentlyStopping: Bool {
        pendingQueue.sync { isStopping }
    }

    public func resetStopping() {
        pendingQueue.sync { isStopping = false }
    }
}
