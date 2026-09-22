import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(os) && !SPEAK_PORTABLE_CORE
import os.log
#endif

/// Shared Deepgram v1/Flux client. Audio is admitted synchronously into a
/// bounded queue, then sent one frame at a time after the actual handshake.
/// No disk I/O or blocking network operation runs on the state queue.
public final class DeepgramLiveClient: FinalizingStreamingTranscriptionClient, @unchecked Sendable {
    public let finalShape: TranscriptFinalShape = .standaloneSegments
    public typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    public typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    private let apiKey: String
    private let model: String
    private let language: String?
    private let sampleRate: Int
    private let makeConnection: ConnectionFactory
    private let schedule: Scheduler
    private let queue = DispatchQueue(label: "DeepgramLiveClient.state")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var run: DeepgramLiveRun
    /// Retains the existing pre-start priming contract. Once a session starts,
    /// its bounded send queue holds connecting audio without silently evicting it.
    let preroll: StreamingAudioPreroll

    public convenience init(
        apiKey: String, model: String = "nova-3", language: String? = nil,
        sampleRate: Int = 16000, session: URLSession = .shared
    ) {
        self.init(
            apiKey: apiKey, model: model, language: language, sampleRate: sampleRate,
            makeConnection: { URLSessionStreamingConnection(session: session, request: $0) },
            schedule: { seconds, action in
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
            }
        )
    }

    public init(
        apiKey: String, model: String = "nova-3", language: String? = nil, sampleRate: Int = 16000,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler = { seconds, action in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: action)
        }
    ) {
        self.apiKey = apiKey
        self.model = model
        self.language = language
        self.sampleRate = sampleRate
        self.makeConnection = makeConnection
        self.schedule = schedule
        self.run = DeepgramLiveRun(sampleRate: sampleRate)
        self.preroll = StreamingAudioPreroll(sampleRate: sampleRate)
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { run.connection?.cancel() }

    public func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        synchronized {
            close(run)
            let active = DeepgramLiveRun(sampleRate: sampleRate)
            run = active
            active.onTranscript = onTranscript
            active.onError = onError
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { fail(DeepgramLiveError.missingAPIKey, active); return }
            guard let url = Self.webSocketURL(model: model, language: language, sampleRate: sampleRate) else {
                fail(DeepgramLiveError.invalidURL, active)
                return
            }
            var request = URLRequest(url: url)
            request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
            let connection = makeConnection(request)
            active.connection = connection
            active.phase = .connecting
            connection.resume { [weak self, weak active] in
                guard let self, let active else { return }
                self.synchronized {
                    guard self.isCurrent(active), !active.ready else { return }
                    active.ready = true
                    if active.phase == .connecting { active.phase = .active }
                    self.log("WebSocket handshake completed")
                    self.pump(active)
                }
            }
            receive(active)
            after(10, active) { client, active in
                if !active.ready { client.fail(DeepgramLiveError.connectionFailed, active) }
            }
        }
    }

    /// Admission happens before work is enqueued, so queued callbacks cannot
    /// themselves retain an unbounded recording when the network stalls.
    public func sendAudio(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        synchronized {
            let active = run
            if active.phase == .idle { preroll.append(audioData); return }
            guard active.phase == .connecting || active.phase == .active else { return }
            guard active.outgoing.count + (active.sending ? 1 : 0) < 256,
                  active.sendBudget.admit(audioData.count) else {
                fail(StreamingClientError.transportStalled(provider: "Deepgram"), active)
                return
            }
            active.outgoing.append(audioData)
            pump(active)
        }
    }

    public func sendAudioSamples(_ samples: UnsafePointer<Float>, frameCount: Int) {
        sendAudio(PCM16Converter.data(from: samples, frameCount: frameCount))
    }

    /// Drains every admitted frame before CloseStream. Trailing finals remain
    /// in the full-session accumulator and are returned once, without a second
    /// onTranscript delivery. Metadata ends the wait; the final drain is bounded.
    public func finishAndWait() async -> String? {
        let active = synchronized { run }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                synchronized {
                    guard isCurrent(active), active.connection != nil else {
                        if active === run { close(active) }
                        continuation.resume(returning: active.accumulated.transcriptOrNil)
                        return
                    }
                    if Task.isCancelled {
                        close(active)
                        continuation.resume(returning: active.accumulated.transcriptOrNil)
                        return
                    }
                    active.waiters.append(continuation)
                    guard active.phase != .finishing else { return }
                    active.phase = .finishing
                    pump(active)
                    // One deadline bounds handshake, audio drain and finalisation.
                    after(5, active) { client, active in
                        if !active.closeSent || active.sending {
                            client.fail(StreamingClientError.transportStalled(provider: "Deepgram"), active)
                        } else { client.close(active) }
                    }
                }
            }
        } onCancel: { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { self.close(active) } }
        }
    }

    public func stop() { synchronized { close(run) } }
    public var isConnected: Bool { synchronized { isCurrent(run) && run.ready } }

    /// Same receive parser used by existing contract tests without a socket.
    func parseTranscriptResponse(_ json: String) { synchronized { parse(json, run) } }

    private func pump(_ active: DeepgramLiveRun) {
        guard isCurrent(active), active.ready, !active.sending, let connection = active.connection else { return }
        let message: StreamingWebSocketMessage
        let audioBytes: Int
        if !active.outgoing.isEmpty {
            let data = active.outgoing.removeFirst()
            message = .binary(data)
            audioBytes = data.count
        } else if active.phase == .finishing, !active.closeSent {
            active.closeSent = true
            message = .text(#"{"type":"CloseStream"}"#)
            audioBytes = 0
        } else { return }
        active.sending = true
        active.sendID += 1
        let sendID = active.sendID
        connection.send(message) { [weak self, weak active] error in
            guard let self, let active else { return }
            self.synchronized {
                guard self.isCurrent(active), active.sendID == sendID else { return }
                active.sending = false
                active.sendBudget.release(audioBytes)
                if let error { self.fail(error, active); return }
                if audioBytes == 0 {
                    self.after(1, active) { client, active in client.close(active) }
                } else { self.pump(active) }
            }
        }
        after(5, active) { client, active in
            if active.sending, active.sendID == sendID {
                client.fail(StreamingClientError.transportStalled(provider: "Deepgram"), active)
            }
        }
    }

    private func receive(_ active: DeepgramLiveRun) {
        guard isCurrent(active), let connection = active.connection else { return }
        connection.receive { [weak self, weak active] result in
            guard let self, let active else { return }
            self.synchronized {
                guard self.isCurrent(active) else { return }
                switch result {
                case .failure(let error):
                    if active.phase == .finishing, active.closeSent, !active.sending {
                        self.close(active)
                    } else { self.fail(error, active) }
                case .success(let message):
                    switch message {
                    case .text(let text): self.parse(text, active)
                    case .binary(let data):
                        if let text = String(data: data, encoding: .utf8) { self.parse(text, active) }
                    }
                    self.receive(active)
                }
            }
        }
    }

    private func parse(_ json: String, _ active: DeepgramLiveRun) {
        guard active === run, active.phase != .closed else { return }
        if Self.isMetadataFrame(json) {
            if active.phase == .finishing, active.closeSent { close(active) }
            return
        }
        guard let event = Self.transcriptEvent(from: json, model: model) else { return }
        if event.isFinal { active.accumulated.append(final: event.text) }
        if active.phase != .finishing { active.onTranscript?(event.text, event.isFinal) }
    }

    private func fail(_ error: Error, _ active: DeepgramLiveRun) {
        guard active === run, active.phase != .closed else { return }
        let onError = active.onError
        let waiters = active.waiters
        active.waiters.removeAll()
        let transcript = active.accumulated.transcriptOrNil
        close(active)
        log("WebSocket session failed")
        // Publish failure before finish returns. The closed run owns these
        // waiters even when the callback starts a replacement session.
        onError?(error)
        waiters.forEach { $0.resume(returning: transcript) }
    }

    private func close(_ active: DeepgramLiveRun) {
        guard active.phase != .closed else { return }
        active.phase = .closed
        let connection = active.connection
        active.connection = nil
        active.outgoing.removeAll(keepingCapacity: false)
        active.sendBudget.reset()
        active.sending = false
        if active === run { preroll.reset() }
        let waiters = active.waiters
        active.waiters.removeAll()
        let transcript = active.accumulated.transcriptOrNil
        connection?.cancel()
        waiters.forEach { $0.resume(returning: transcript) }
        active.onTranscript = nil
        active.onError = nil
    }

    private func isCurrent(_ active: DeepgramLiveRun) -> Bool { active === run && active.phase != .closed }

    private func after(_ seconds: TimeInterval, _ active: DeepgramLiveRun,
                       action: @escaping @Sendable (DeepgramLiveClient, DeepgramLiveRun) -> Void) {
        schedule(seconds) { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.isCurrent(active) { action(self, active) } }
        }
    }

    private func synchronized<Value>(_ action: () -> Value) -> Value {
        if DispatchQueue.getSpecific(key: queueKey) == true { return action() }
        return queue.sync(execute: action)
    }

    private func log(_ event: String) {
        #if canImport(os) && !SPEAK_PORTABLE_CORE
        SpeakLogger.logger(category: "DeepgramLiveClient").info("\(event, privacy: .public)")
        #endif
    }
}
// MARK: - Error Types

public enum DeepgramLiveError: LocalizedError {
    case invalidURL
    case connectionFailed
    case sendFailed
    case missingAPIKey

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Failed to construct Deepgram WebSocket URL"
        case .connectionFailed:
            return "Failed to establish WebSocket connection to Deepgram"
        case .sendFailed:
            return "Failed to send audio data to Deepgram"
        case .missingAPIKey:
            return "Deepgram API key is missing. Please configure it in Settings."
        }
    }
}
