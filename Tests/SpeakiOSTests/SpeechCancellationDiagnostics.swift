#if os(iOS)
import Foundation

/// Observes only the session supplied by the test. No request, response body, URL or error text is retained.
/// The per-request policy implements didCreateTask, so a session observer must not claim to see creation.
/// Apple forwards task-delegate methods not implemented by that policy to the session delegate; an
/// absent completion callback is still recorded as unknown, not proof of a running or cancelled task.
final class SpeechCancellationDiagnostics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    enum Phase: String {
        case protocolOutcomeDelivered = "protocol_outcome_delivered"
        case protocolStopLoading = "protocol_stop_loading"
        case protocolStartWaitReturned = "protocol_start_wait_returned"
        case callerCancelRequested = "caller_cancel_requested"
        case clientStopRequested = "client_stop_requested"
        case callerReturned = "caller_returned"
        case callerCancellationError = "caller_cancellation_error"
        case callerOtherError = "caller_other_error"
        case sessionDelegateCompletionObserved = "session_delegate_completion_observed"
        case postFailureTaskQueryReturned = "post_failure_task_query_returned"
    }

    private let lock = NSLock()
    private let start = ProcessInfo.processInfo.systemUptime
    private var phases: [[String: Any]] = []
    private var completions: [[String: Any]] = []
    private var tasks: [[String: Any]]?

    func record(_ phase: Phase) {
        lock.withLock {
            guard phases.count < 32 else { return }
            phases.append(["phase": phase.rawValue, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start])
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let category: String
        if let error = error as NSError? {
            category = error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
                ? "url_cancelled" : "other_error"
        } else {
            category = "no_error"
        }
        lock.withLock {
            guard completions.count < 8 else { return }
            completions.append(["state": task.state.rawValue, "outcome": category])
        }
        record(.sessionDelegateCompletionObserved)
    }

    func recordTasks(_ pending: [URLSessionTask]) {
        let records: [[String: Any]] = pending.prefix(8).map {
            ["state": $0.state.rawValue, "responsePresent": $0.response != nil,
             "receivedByteCount": $0.countOfBytesReceived]
        }
        lock.withLock { tasks = records }
        record(.postFailureTaskQueryReturned)
    }

    func snapshot() -> String {
        let record: [String: Any] = lock.withLock {
            ["version": 1, "phases": phases, "observedSessionCompletions": completions,
             "taskQueryReturned": tasks != nil, "sampledTasks": tasks ?? [],
             "delegateEventAbsenceMeans": "unknown; task-specific delegate may intercept events"]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "Diagnostic encoding unavailable" }
        return text
    }
}
#endif
