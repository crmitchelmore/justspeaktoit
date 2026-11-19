import Foundation

/// The gate between "the socket is open" and "the service will accept audio".
///
/// Every streaming provider here has a handshake frame — Speechmatics'
/// `RecognitionStarted`, Rev AI's `connected`, Voxtral's `session.created`,
/// xAI's `transcript.created` — and rejects audio sent before it. Capture
/// starts as soon as the engine runs, so `StreamingAudioPreroll` holds the
/// leading audio; this is the other half of that arrangement, for the case
/// where the *stop* lands before the handshake completes.
///
/// Without it, a short recording finished during an ordinary handshake threw
/// away everything the user said: the client saw "not ready", called `stop()`,
/// and `stop()` cleared the preroll and cancelled a socket that was moments
/// from becoming usable. A bounded wait commits that capture when readiness
/// arrives inside the budget, and still terminates a session that cannot
/// become ready (issues #947, #949).
public final class StreamingSessionReadiness: @unchecked Sendable {
    /// How long a graceful finish waits for the handshake before giving up on
    /// the held capture. Comfortably inside every client's finish budget, so a
    /// stop stays bounded by the budget the caller was promised.
    public static let defaultBudget: TimeInterval = 2

    private let lock = NSLock()
    private var ready = false
    private var signal = DispatchSemaphore(value: 0)

    public init() {}

    /// Whether the handshake frame has arrived for the current session.
    public var isReady: Bool {
        lock.withLock { ready }
    }

    /// Records the handshake frame and releases anyone waiting for it.
    public func markReady() {
        let semaphore: DispatchSemaphore? = lock.withLock {
            guard !ready else { return nil }
            ready = true
            return signal
        }
        semaphore?.signal()
    }

    /// Clears readiness for a new session. A waiter blocked on the previous
    /// session's semaphore is released so it cannot outlive the session.
    public func reset() {
        let previous: DispatchSemaphore = lock.withLock {
            let previous = signal
            ready = false
            signal = DispatchSemaphore(value: 0)
            return previous
        }
        previous.signal()
    }

    /// Waits up to `budget` for the handshake, and answers whether it arrived.
    ///
    /// Returns immediately when the session is already ready. Blocks the
    /// calling thread, so callers use it from the background queue their
    /// finalisation already runs on, never from the main actor.
    @discardableResult
    public func waitUntilReady(budget: TimeInterval = StreamingSessionReadiness.defaultBudget) -> Bool {
        let semaphore: DispatchSemaphore? = lock.withLock {
            ready ? nil : signal
        }
        guard let semaphore else { return true }
        _ = semaphore.wait(timeout: .now() + max(budget, 0))
        // `reset()` also signals, so readiness is re-read rather than inferred
        // from the wait's own result.
        return isReady
    }
}

/// A ceiling on outbound audio a streaming client may have in flight.
///
/// `URLSessionWebSocketTask.send` accepts work whether or not the connection
/// is making progress, so a stalled socket turns a live recording into
/// unbounded retained memory: every captured chunk, its base64 or JSON
/// encoding, and the completion closure holding it, for as long as the user
/// keeps talking.
///
/// The budget is expressed in seconds of PCM so it means the same thing at any
/// sample rate. Exceeding it is not a reason to drop audio quietly — that would
/// silently lose speech — it is evidence the transport has stopped working, and
/// the client reports it as a transport failure, which cancels the socket and
/// releases everything retained with it.
public final class StreamingAudioSendBudget: @unchecked Sendable {
    /// Seconds of audio that may be in flight before the transport is treated
    /// as stalled. Far more than any healthy socket accumulates, and small
    /// enough that a dead one is caught in seconds rather than minutes.
    public static let defaultBudgetSeconds: Double = 30

    private let maximumByteCount: Int
    private let lock = NSLock()
    private var inFlightByteCount = 0

    /// - Parameters:
    ///   - sampleRate: Capture sample rate in Hz.
    ///   - seconds: Budget in seconds of audio.
    ///   - bytesPerFrame: 2 for the PCM16 mono every streaming provider uses.
    public init(
        sampleRate: Int,
        seconds: Double = StreamingAudioSendBudget.defaultBudgetSeconds,
        bytesPerFrame: Int = 2
    ) {
        let rate = max(sampleRate, 1)
        let budget = max(seconds, 0)
        self.maximumByteCount = max(Int(Double(rate * max(bytesPerFrame, 1)) * budget), 1)
    }

    /// Bytes currently submitted to the transport and not yet completed.
    public var inFlightBytes: Int {
        lock.withLock { inFlightByteCount }
    }

    /// Reserves room for one outbound frame, or answers `false` when the
    /// transport already holds more than the budget allows.
    public func admit(_ byteCount: Int) -> Bool {
        lock.withLock {
            guard inFlightByteCount + byteCount <= maximumByteCount else { return false }
            inFlightByteCount += byteCount
            return true
        }
    }

    /// Releases a frame's reservation when its send completes, succeed or fail.
    public func release(_ byteCount: Int) {
        lock.withLock {
            inFlightByteCount = max(0, inFlightByteCount - byteCount)
        }
    }

    /// Clears the reservation for a new session.
    public func reset() {
        lock.withLock { inFlightByteCount = 0 }
    }
}
