import Foundation

/// Hands a custom-scheme iCloud sign-in callback to the sign-in waiting for it.
///
/// With the `custom-scheme` callback the browser does not reach the app over a
/// socket: it launches `justspeaktoit://cloudkit-sign-in?ckWebAuthToken=…`,
/// which the running window receives as an activation. The sign-in opens a
/// ticket before it opens the browser, so a callback that arrives quickly is
/// kept for it, and waits on that ticket for a bounded time.
///
/// Only an open ticket accepts a token. A callback with no sign-in waiting is
/// refused, so a link opened by some other page cannot sign this PC in to an
/// Apple ID nobody asked for. Opening a new ticket ends the previous wait.
public final class DesktopSignInCallbackInbox: @unchecked Sendable {
    public struct Ticket: Equatable, Sendable {
        fileprivate let id: UUID
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case timedOut
        case superseded

        public var errorDescription: String? {
            switch self {
            case .timedOut: return "The browser did not return from Apple ID sign-in in time."
            case .superseded: return "Another iCloud sign-in started."
            }
        }
    }

    private let lock = NSLock()
    private var current: UUID?
    private var token: String?
    private var continuation: CheckedContinuation<String, Error>?

    public init() {}

    /// Opens a ticket for the next callback, ending any earlier wait.
    public func open() -> Ticket {
        let ticket = Ticket(id: UUID())
        let previous = lock.withLock { () -> CheckedContinuation<String, Error>? in
            defer { current = ticket.id; token = nil; continuation = nil }
            return continuation
        }
        previous?.resume(throwing: Failure.superseded)
        return ticket
    }

    /// Delivers a callback's token. `false` when no sign-in is waiting, in which
    /// case the token is dropped.
    @discardableResult
    public func deliver(_ webAuthToken: String) -> Bool {
        let waiting = lock.withLock { () -> (Bool, CheckedContinuation<String, Error>?) in
            guard current != nil, token == nil else { return (false, nil) }
            guard let continuation else {
                token = webAuthToken
                return (true, nil)
            }
            self.continuation = nil
            current = nil
            return (true, continuation)
        }
        waiting.1?.resume(returning: webAuthToken)
        return waiting.0
    }

    /// Whether a sign-in is waiting for a callback.
    public var isWaiting: Bool { lock.withLock { current != nil } }

    /// Whether `wait(for:timeout:)` is suspended on the open ticket (tests).
    var hasWaiter: Bool { lock.withLock { continuation != nil } }

    /// Waits for `ticket`'s token for at most `timeout`; cancellation ends the
    /// wait. The ticket is closed whatever the outcome.
    public func wait(for ticket: Ticket, timeout: Duration) async throws -> String {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.fail(ticket, with: Failure.timedOut)
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let outcome = lock.withLock { () -> Result<String, Error>? in
                    guard current == ticket.id else { return .failure(Failure.superseded) }
                    if let token {
                        self.token = nil
                        current = nil
                        return .success(token)
                    }
                    self.continuation = continuation
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            fail(ticket, with: CancellationError())
        }
    }

    /// Closes `ticket` without waiting, dropping anything delivered to it.
    public func close(_ ticket: Ticket) {
        fail(ticket, with: CancellationError())
    }

    private func fail(_ ticket: Ticket, with error: Error) {
        let waiting = lock.withLock { () -> CheckedContinuation<String, Error>? in
            guard current == ticket.id else { return nil }
            defer { current = nil; token = nil; continuation = nil }
            return continuation
        }
        waiting?.resume(throwing: error)
    }
}
