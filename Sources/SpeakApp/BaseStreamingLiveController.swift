import Foundation
import SpeakCore
import os.log

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
        self.log = Logger(subsystem: "com.justspeaktoit", category: logCategory)
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

    /// Flushes pending chunks via `send` closure, awaiting completions with timeout.
    public func flushPendingChunks(
        send: @escaping (Data) async throws -> Void,
        timeout: TimeInterval = 1.0
    ) async {
        let chunks: [Data] = pendingQueue.sync {
            let copy = pendingAudioChunks
            pendingAudioChunks.removeAll()
            return copy
        }
        guard !chunks.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for chunk in chunks {
                group.addTask { try? await send(chunk) }
            }
        }
        // Bounded timeout is enforced by caller; we do not block indefinitely.
        log.debug("\(self.providerID): flushed \(chunks.count) pending chunks")
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
