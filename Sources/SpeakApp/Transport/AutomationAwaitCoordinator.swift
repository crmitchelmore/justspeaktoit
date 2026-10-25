#if os(macOS)
import Foundation
import SpeakCore

/// Await-only lifetime policy. Legacy commands retain their existing patience/replay semantics.
/// Each connection owns one subscription; only losing the last subscriber cancels the shared wait.
@MainActor
final class AutomationAwaitCoordinator {
    typealias Handler = (AutomationRequest) async -> AutomationResponse
    private struct Fingerprint: Equatable {
        let capture: UUID
        let since: UUID?
        let timeout: TimeInterval
    }
    private struct Terminal {
        let fingerprint: Fingerprint
        let response: AutomationResponse
    }
    private struct Run {
        let identifier: String
        let epoch: UUID
        let fingerprint: Fingerprint
        let deadline: ContinuousClock.Instant
        let work: Task<Void, Never>
        let timer: Task<Void, Never>
        var subscribers: [UUID: CheckedContinuation<AutomationResponse, Never>]
    }
    var didChangeSubscribers: ((String, Int) -> Void)?
    private var handler: Handler?
    private var runs: [Data: Run] = [:]
    private var terminal: [Data: Terminal] = [:]
    private var order: [Data] = []
    private let now: () -> ContinuousClock.Instant

    init(now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }) {
        self.now = now
    }

    func activate(_ handler: @escaping Handler) { self.handler = handler }

    func deactivate() {
        self.handler = nil
        let oldRuns = self.runs
        self.runs.removeAll()
        self.terminal.removeAll()
        self.order.removeAll()
        for run in oldRuns.values {
            run.work.cancel()
            run.timer.cancel()
            let response = Self.failure(run.identifier, .appUnavailable,
                                        "Automation stopped; waits cannot resume across restart.")
            for subscriber in run.subscribers.values { subscriber.resume(returning: response) }
        }
    }

    func respond(to request: AutomationRequest) async -> AutomationResponse {
        let subscriber = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.subscribe(request, subscriber: subscriber, continuation: continuation)
                if Task.isCancelled { self.disconnect(id: request.id, subscriber: subscriber) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.disconnect(id: request.id, subscriber: subscriber) }
        }
    }

    private func subscribe(_ request: AutomationRequest, subscriber: UUID,
                           continuation: CheckedContinuation<AutomationResponse, Never>) {
        let fingerprint: Fingerprint
        do {
            fingerprint = try Self.fingerprint(for: request)
        } catch {
            continuation.resume(returning: .failure(id: request.id, command: .awaitTranscript,
                error: error as? AutomationError ?? AutomationError(code: .invalidArgument, message: "Invalid wait.")))
            return
        }
        let key = Data(request.id.utf8)
        let prior = self.runs[key]?.fingerprint ?? self.terminal[key]?.fingerprint
        guard prior == nil || prior == fingerprint else {
            continuation.resume(returning: Self.failure(request.id, .invalidArgument,
                                                       "Request ID was already used with different await arguments."))
            return
        }
        if let cached = self.terminal[key] {
            continuation.resume(returning: cached.response)
            return
        }
        if self.runs[key] != nil {
            self.runs[key]?.subscribers[subscriber] = continuation
            self.didChangeSubscribers?(request.id, self.runs[key]?.subscribers.count ?? 0)
            return
        }
        guard let handler = self.handler else {
            continuation.resume(returning: Self.failure(request.id, .appUnavailable, "Automation is stopped."))
            return
        }
        guard self.runs.count < AutomationLimits.maxTranscriptWaits else {
            continuation.resume(returning: Self.failure(request.id, .internalError, "Too many active capture waits."))
            return
        }
        let epoch = UUID()
        let deadline = self.now().advanced(by: .seconds(fingerprint.timeout))
        let work: Task<Void, Never> = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let response = await handler(request)
            self?.finish(id: request.id, epoch: epoch, response: response)
        }
        let timer: Task<Void, Never> = Task { @MainActor [weak self] in
            do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            self?.finish(id: request.id, epoch: epoch,
                         response: Self.failure(request.id, .timedOut, "Capture wait timed out."))
        }
        self.runs[key] = Run(identifier: request.id, epoch: epoch, fingerprint: fingerprint, deadline: deadline,
                             work: work, timer: timer, subscribers: [subscriber: continuation])
        self.didChangeSubscribers?(request.id, 1)
    }

    private static func fingerprint(for request: AutomationRequest) throws -> Fingerprint {
        _ = try request.validated()
        guard request.command == .awaitTranscript, let capture = request.captureID.flatMap(UUID.init(uuidString:))
        else { throw AutomationError(code: .invalidArgument, message: "A named capture is required.") }
        return Fingerprint(capture: capture, since: request.sinceID.flatMap(UUID.init(uuidString:)),
                           timeout: request.resolvedTimeout)
    }

    private func disconnect(id: String, subscriber: UUID) {
        let key = Data(id.utf8)
        guard var run = self.runs[key],
            let continuation = run.subscribers.removeValue(forKey: subscriber) else { return }
        let response = Self.failure(id, .appUnavailable, "Capture wait connection cancelled.")
        continuation.resume(returning: response)
        self.runs[key] = run
        self.didChangeSubscribers?(id, run.subscribers.count)
        if run.subscribers.isEmpty { self.finish(id: id, epoch: run.epoch, response: response) }
    }

    private func finish(id: String, epoch: UUID, response: AutomationResponse) {
        let key = Data(id.utf8)
        guard let run = self.runs[key], run.epoch == epoch else { return }
        self.runs.removeValue(forKey: key)
        // A result processed at or after the original monotonic deadline loses, including a starved timer.
        let settled = self.now() >= run.deadline
            ? Self.failure(id, .timedOut, "Capture wait timed out.") : response
        run.work.cancel()
        run.timer.cancel()
        self.terminal[key] = Terminal(fingerprint: run.fingerprint, response: settled)
        self.order.append(key)
        while self.order.count > AutomationRequestCoordinator.maxRememberedRequests {
            self.terminal.removeValue(forKey: self.order.removeFirst())
        }
        for subscriber in run.subscribers.values { subscriber.resume(returning: settled) }
    }

    private static func failure(_ id: String, _ code: AutomationErrorCode, _ message: String) -> AutomationResponse {
        .failure(id: id, command: .awaitTranscript, error: AutomationError(code: code, message: message))
    }
}
#endif
