import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared lifecycle for handshake-gated providers with an explicit end frame.
/// All effects carry a run identity; admission includes the in-flight PCM.
final class StreamingProviderSession: @unchecked Sendable {
    typealias ConnectionFactory = @Sendable (URLRequest) -> any StreamingWebSocketConnection
    typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    enum Event {
        case ready
        case interim(String)
        case final(String, id: String? = nil)
        case complete
        case failure(Error)
        case reconnect
    }

    struct FinishResult: Sendable {
        let transcript: String?
        let hasFinal: Bool
        let failed: Bool
    }

    struct Configuration {
        let provider: String
        let sampleRate: Int
        let shape: TranscriptFinalShape
        let finishBudget: TimeInterval
        let request: () throws -> URLRequest
        let setup: (() throws -> StreamingWebSocketMessage)?
        let audio: (Data, Bool) throws -> StreamingWebSocketMessage
        let end: StreamingWebSocketMessage
        let decode: (String) -> [Event]
        var finalCompletes = false
        var cumulativeInterims = false
        var cumulativeSegmentUpdates = false
        var unsolicitedCompletionFails = false
        var maximumReconnects = 0
        var retryBeforeReady: (Error) -> Bool = { _ in false }
        var transportError: (Error) -> Error = { $0 }
    }

    private typealias Run = StreamingProviderRun

    private let configuration: Configuration
    private let makeConnection: ConnectionFactory
    private let schedule: Scheduler
    private let queue = DispatchQueue(label: "StreamingProviderSession.state")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var run: Run
    let preroll: StreamingAudioPreroll

    init(
        configuration: Configuration,
        makeConnection: @escaping ConnectionFactory,
        schedule: @escaping Scheduler
    ) {
        self.configuration = configuration
        self.makeConnection = makeConnection
        self.schedule = schedule
        run = Run(configuration)
        preroll = StreamingAudioPreroll(sampleRate: configuration.sampleRate)
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { run.connection?.cancel() }

    var isReady: Bool { synchronized { !self.run.closed && self.run.ready } }
    func beginSession(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        self.synchronized {
            self.close(self.run)
            self.run = Run(self.configuration)
            self.run.onTranscript = onTranscript
            self.run.onError = onError
        }
    }

    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        synchronized {
            let primed = self.run.onTranscript == nil && !self.run.closed ? self.preroll.drain() : []
            self.beginSession(onTranscript: onTranscript, onError: onError)
            let active = self.run
            do {
                let request = try self.configuration.request()
                self.connect(active, request: request)
                for frame in primed { self.admit(frame, active) }
            } catch {
                self.fail(error, active)
            }
        }
    }

    func sendAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        synchronized {
            if self.run.onTranscript == nil && !self.run.closed { self.preroll.append(data); return }
            guard !self.run.closed, !self.run.finishing else { return }
            self.admit(data, self.run)
        }
    }

    private func admit(_ data: Data, _ active: Run) {
        guard current(active) else { return }
        guard active.outgoing.count + (active.sending ? 1 : 0) < 256, active.budget.admit(data.count) else {
            fail(StreamingClientError.transportStalled(provider: configuration.provider), active)
            return
        }
        active.outgoing.append(data)
        pump(active)
    }

    func stop() { synchronized { self.close(self.run) } }

    func finishAndWait() async -> String? {
        (await finishAndWaitResult()).transcript
    }

    func finishAndWaitResult() async -> FinishResult {
        let active = synchronized { self.run }
        let text = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                synchronized {
                    guard self.current(active), active.connection != nil, !Task.isCancelled else {
                        let text = self.transcript(active)
                        if self.current(active) { self.close(active) }
                        continuation.resume(returning: text)
                        return
                    }
                    active.waiters.append(continuation)
                    guard !active.finishing else { return }
                    active.finishing = true
                    self.after(self.configuration.finishBudget, active) { client, active in
                        client.fail(client.finishError(active), active)
                    }
                    self.pump(active)
                }
            }
        } onCancel: { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.current(active) { self.close(active) } }
        }
        return synchronized { FinishResult(transcript: text, hasFinal: active.hasFinal, failed: active.failed) }
    }

    /// Offline seam for the existing Apple contract tests, using the same decoder.
    func ingest(_ text: String) { synchronized { self.handle(text, self.run) } }

    func awaitFinal(budget: TimeInterval, whenArmed: () -> Void) async -> String? {
        let active = synchronized { self.run }
        return await withCheckedContinuation { continuation in
            let armed = self.synchronized {
                guard self.current(active) else { return false }
                active.finishing = true
                active.endSent = true
                active.waiters.append(continuation)
                self.after(budget, active) { client, active in client.fail(client.finishError(active), active) }
                return true
            }
            if armed { whenArmed() } else {
                continuation.resume(returning: self.synchronized { self.transcript(active) })
            }
        }
    }
}

extension StreamingProviderSession {
    private func connect(_ active: Run, request: URLRequest) {
        guard current(active) else { return }
        let connection = makeConnection(request)
        active.connection = connection
        active.didOpen = false
        active.setupSent = false
        active.ready = false
        active.firstAudio = true
        after(10, active) { client, active in
            guard active.connection === connection, !active.ready else { return }
            client.fail(ProviderStreamingError.sessionNotReady(client.configuration.provider), active)
        }
        connection.resume { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized {
                guard self.current(active), active.connection === connection, !active.didOpen else { return }
                active.didOpen = true
                do {
                    if let setup = self.configuration.setup {
                        let message = try setup()
                        active.setupSent = true
                        self.send(message, bytes: 0, active, connection)
                    } else {
                        active.ready = true
                        self.pump(active)
                    }
                } catch { self.fail(error, active) }
            }
        }
        if current(active), active.connection === connection { receive(active, connection) }
    }

    private func receive(_ active: Run, _ connection: any StreamingWebSocketConnection) {
        connection.receive { [weak self, weak active] result in
            guard let self, let active else { return }
            self.synchronized {
                guard self.current(active), active.connection === connection else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .text(let text): self.handle(text, active)
                    case .binary(let data):
                        if let text = String(data: data, encoding: .utf8) { self.handle(text, active) }
                    }
                    if self.current(active), active.connection === connection { self.receive(active, connection) }
                case .failure(let error):
                    if !active.ready, !active.finishing, self.configuration.retryBeforeReady(error),
                       self.reconnect(active) { return }
                    let failure = active.finishing ? self.finishError(active) : self.configuration.transportError(error)
                    self.fail(failure, active)
                }
            }
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func handle(_ text: String, _ active: Run) {
        guard current(active) else { return }
        for event in configuration.decode(text) {
            guard current(active) else { return }
            switch event {
            case .ready:
                guard active.connection == nil || (active.didOpen && active.setupSent) else { continue }
                active.ready = true
                pump(active)
            case .interim(let text):
                active.interim = text
                if !active.finishing { active.onTranscript?(text, false) }
            case .final(let text, let id):
                if let id, !active.seenFinalIDs.insert(id).inserted { continue }
                active.accumulated.append(final: text, eventID: id)
                active.interim = ""
                active.hasFinal = true
                if active.endSent, configuration.finalCompletes {
                    close(active)
                } else if !active.finishing {
                    let cumulative = configuration.shape == .cumulativeTranscript
                        || configuration.cumulativeSegmentUpdates
                    let delivered = cumulative ? transcript(active) ?? "" : text
                    active.onTranscript?(delivered, !configuration.cumulativeSegmentUpdates)
                }
            case .complete:
                // A normal turn boundary before our end frame cannot acknowledge a stop.
                if active.endSent {
                    close(active)
                } else if configuration.unsolicitedCompletionFails {
                    fail(ProviderStreamingError.missingCompletion(configuration.provider), active)
                }
            case .failure(let error):
                fail(error, active)
            case .reconnect:
                if active.finishing || !reconnect(active) {
                    fail(ProviderStreamingError.missingCompletion(configuration.provider), active)
                }
            }
        }
    }

    private func reconnect(_ active: Run) -> Bool {
        guard current(active), !active.finishing, !active.sending || !active.ready,
              active.reconnects < configuration.maximumReconnects else { return false }
        active.reconnects += 1
        let previous = active.connection
        active.connection = nil
        active.ready = false
        active.sending = false
        active.sendID += 1
        previous?.cancel()
        do {
            connect(active, request: try configuration.request())
        } catch {
            fail(error, active)
        }
        return true
    }

    private func pump(_ active: Run) {
        guard current(active), active.didOpen, active.ready, !active.sending,
              let connection = active.connection else { return }
        if !active.outgoing.isEmpty {
            let audio = active.outgoing.removeFirst()
            do {
                let message = try configuration.audio(audio, active.firstAudio)
                active.firstAudio = false
                send(message, bytes: audio.count, active, connection)
            } catch { fail(error, active) }
        } else if active.finishing, !active.endSent {
            active.endSent = true
            send(configuration.end, bytes: 0, active, connection)
        }
    }

    private func send(
        _ message: StreamingWebSocketMessage, bytes: Int, _ active: Run,
        _ connection: any StreamingWebSocketConnection
    ) {
        active.sending = true
        active.sendID += 1
        let sendID = active.sendID
        after(5, active) { client, active in
            guard active.connection === connection, active.sending, active.sendID == sendID else { return }
            client.fail(StreamingClientError.transportStalled(provider: client.configuration.provider), active)
        }
        connection.send(message) { [weak self, weak active] error in
            guard let self, let active else { return }
            self.synchronized {
                guard self.current(active), active.connection === connection,
                      active.sending, active.sendID == sendID else { return }
                active.sending = false
                active.budget.release(bytes)
                if let error { self.fail(self.configuration.transportError(error), active) } else { self.pump(active) }
            }
        }
    }

    private func finishError(_ active: Run) -> Error {
        if !active.ready { return ProviderStreamingError.sessionNotReady(configuration.provider) }
        if active.sending || !active.outgoing.isEmpty {
            return StreamingClientError.transportStalled(provider: configuration.provider)
        }
        return ProviderStreamingError.missingCompletion(configuration.provider)
    }

    private func transcript(_ active: Run) -> String? {
        if configuration.cumulativeInterims, !active.interim.isEmpty { return active.interim }
        return active.accumulated.transcriptOrNil
    }

    private func fail(_ error: Error, _ active: Run) {
        guard current(active) else { return }
        active.failed = true
        let callback = active.onError
        let waiters = active.waiters
        active.waiters.removeAll()
        let text = transcript(active)
        close(active)
        // Detach first, then publish failure before returning recovery text.
        callback?(error)
        waiters.forEach { $0.resume(returning: text) }
    }

    private func close(_ active: Run) {
        guard !active.closed else { return }
        active.closed = true
        let connection = active.connection
        active.connection = nil
        active.outgoing.removeAll()
        active.budget.reset()
        let waiters = active.waiters
        active.waiters.removeAll()
        let text = transcript(active)
        active.onTranscript = nil
        active.onError = nil
        if active === run { preroll.reset() }
        connection?.cancel()
        waiters.forEach { $0.resume(returning: text) }
    }

    private func current(_ active: Run) -> Bool { active === run && !active.closed }

    private func after(
        _ seconds: TimeInterval, _ active: Run,
        action: @escaping @Sendable (StreamingProviderSession, Run) -> Void
    ) {
        schedule(seconds) { [weak self, weak active] in
            guard let self, let active else { return }
            self.synchronized { if self.current(active) { action(self, active) } }
        }
    }

    private func synchronized<Value>(_ action: () -> Value) -> Value {
        if DispatchQueue.getSpecific(key: queueKey) == true { return action() }
        return queue.sync(execute: action)
    }
}

public enum ProviderStreamingError: LocalizedError, Equatable {
    case sessionNotReady(String)
    case missingCompletion(String)

    public var errorDescription: String? {
        switch self {
        case .sessionNotReady(let provider): return "\(provider) did not become ready to receive audio."
        case .missingCompletion(let provider): return "\(provider) ended without confirming transcription completion."
        }
    }
}
