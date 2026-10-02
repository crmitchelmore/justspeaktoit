import Foundation

/// How a local automation server answers a request, shared by every transport.
///
/// The macOS UNIX-socket server and the Windows named-pipe server own only bytes
/// and connection lifetime. Everything a client can observe about how its
/// request is answered lives here, once:
///
/// - a completed reply is replayed for a retry with the same id *and* command,
///   so a client that retries after a timeout cannot start a second session,
///   and a client that reuses an id for another command never receives the
///   earlier command's answer;
/// - a retry of a command that is still running joins that run;
/// - a request is validated against the shared bounds before a command runs,
///   because any local process can write to the endpoint;
/// - the caller's deadline is answered at the deadline without abandoning the
///   command, whose own completion still fills the replay cache.
///
/// Isolation-agnostic: the macOS server calls it from the main actor and the
/// Windows server from its connection threads, whose main thread is inside the
/// Win32 message loop. State changes happen under a lock that is never held
/// across a suspension point.
public final class AutomationRequestCoordinator: @unchecked Sendable {
    /// Runs one validated command. Implementations hop to whatever isolation the
    /// app's managers require.
    public typealias Handler = @Sendable (AutomationRequest) async -> AutomationResponse

    /// Completed replies kept for replay. Bounded so a client cycling ids cannot
    /// grow the cache without limit.
    public static let maxRememberedRequests = 64

    private struct Key: Hashable {
        let id: String
        let command: AutomationCommand
    }

    private enum Admission {
        case answered(AutomationResponse)
        case running(Task<AutomationResponse, Never>)
    }

    private let lock = NSLock()
    private var handler: Handler?
    /// Bumped by every deactivation. A command orphaned by `deactivate()` keeps
    /// running, and without this its late reply could land in the caches of a
    /// later activation and be replayed to a client that connected after an
    /// off/on toggle — or evict a new run that reused its key.
    private var generation: UInt64 = 0
    private var completed: [Key: AutomationResponse] = [:]
    private var completionOrder: [Key] = []
    private var inFlight: [Key: Task<AutomationResponse, Never>] = [:]

    public init() {}

    /// Whether commands are currently being answered.
    public var isActive: Bool {
        self.lock.withLock { self.handler != nil }
    }

    /// Starts answering commands with `handler`.
    public func activate(_ handler: @escaping Handler) {
        self.lock.withLock { self.handler = handler }
    }

    /// Stops answering commands and forgets everything this activation saw.
    ///
    /// Running commands are cancelled, not awaited: they own app state and finish
    /// on their own, but their replies are dropped rather than cached.
    public func deactivate() {
        let orphaned: [Task<AutomationResponse, Never>] = self.lock.withLock {
            self.generation &+= 1
            self.handler = nil
            let running = Array(self.inFlight.values)
            self.inFlight.removeAll()
            self.completed.removeAll()
            self.completionOrder.removeAll()
            return running
        }
        for work in orphaned {
            work.cancel()
        }
    }

    /// Answers `request`: a replayed reply, a joined run, a validation failure, or
    /// the command's own result — or `timed_out` once the request's deadline
    /// passes, whichever comes first.
    public func respond(to request: AutomationRequest) async -> AutomationResponse {
        switch self.admit(request) {
        case .answered(let response):
            return response
        case .running(let work):
            return await AutomationDeadline.value(
                of: work,
                within: request.resolvedTimeout,
                id: request.id,
                command: request.command
            )
        }
    }

    private func admit(_ request: AutomationRequest) -> Admission {
        let key = Key(id: request.id, command: request.command)
        return self.lock.withLock {
            if let cached = self.completed[key] {
                return .answered(cached)
            }
            // A retry of a command that is still running joins the original run
            // rather than starting a second dictation session.
            if let existing = self.inFlight[key] {
                return .running(existing)
            }
            let validated: AutomationRequest
            do {
                validated = try request.validated()
            } catch {
                return .answered(.failure(
                    id: request.id,
                    command: request.command,
                    error: error as? AutomationError
                        ?? AutomationError(code: .invalidArgument, message: "Automation request was rejected.")
                ))
            }
            guard let handler = self.handler else {
                return .answered(.failure(
                    id: request.id,
                    command: request.command,
                    error: AutomationError(code: .internalError, message: "Automation is not wired up in this build.")
                ))
            }
            let generation = self.generation
            // Created under the lock, so the command's completion cannot reach
            // `finish` before the run is registered as in flight.
            let work = Task { [weak self] () -> AutomationResponse in
                let response = await handler(validated)
                self?.finish(key: key, response: response, generation: generation)
                return response
            }
            self.inFlight[key] = work
            return .running(work)
        }
    }

    private func finish(key: Key, response: AutomationResponse, generation: UInt64) {
        self.lock.withLock {
            guard generation == self.generation else { return }
            self.inFlight.removeValue(forKey: key)
            self.completed[key] = response
            self.completionOrder.append(key)
            while self.completionOrder.count > Self.maxRememberedRequests {
                let evicted = self.completionOrder.removeFirst()
                self.completed.removeValue(forKey: evicted)
            }
        }
    }
}
