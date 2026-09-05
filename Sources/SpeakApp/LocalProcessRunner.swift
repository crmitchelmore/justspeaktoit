#if !APP_STORE
import Darwin
import Foundation

/// Subprocess work has different budgets from network requests: a compiler may
/// need minutes, while import probes and an interactive inference must finish soon.
enum LocalProcessRunner {
    static let setupTimeout: TimeInterval = 15 * 60
    static let probeTimeout: TimeInterval = 30
    static let inferenceTimeout: TimeInterval = 120
    static let extractionTimeout: TimeInterval = 120

    static func run(
        executableURL: URL,
        arguments: [String],
        standardInput: Data? = nil,
        environment: [String: String] = [:],
        timeout: TimeInterval
    ) async throws -> String {
        guard timeout.isFinite, timeout > 0 else { throw LocalProcessError.invalidTimeout }
        let cancellation = LocalProcessCancellation()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let result = Result {
                        try cancellation.check(deadline: deadline, timeout: timeout)
                        let process = try OwnedLocalProcess(
                            executableURL: executableURL, arguments: arguments, environment: environment
                        )
                        defer { process.finish() }
                        return try process.collect(
                            input: standardInput ?? Data(), cancellation: cancellation,
                            deadline: deadline, timeout: timeout
                        )
                    }
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

enum LocalProcessError: LocalizedError {
    case invalidTimeout
    case timedOut(TimeInterval)
    case failed(String)
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case .invalidTimeout:
            return "The local process timeout must be a positive finite duration."
        case .timedOut(let seconds):
            let duration = String(format: "%.0f", seconds)
            return "Local processing timed out after \(duration) seconds."
        case .failed(let details):
            return details
        case .systemCall(let operation, let code):
            return "Local process \(operation) failed (POSIX error \(code))."
        }
    }
}

final class LocalProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check(deadline: TimeInterval, timeout: TimeInterval) throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled { throw CancellationError() }
        if ProcessInfo.processInfo.systemUptime >= deadline { throw LocalProcessError.timedOut(timeout) }
    }
}

/// Only the worker queue touches this object or its descriptors. The process
/// starts in its own group atomically, before any executable code can fork.
/// Teardown covers descendants that remain in that group, not intentionally
/// detached sessions. A kernel-stuck spawn itself cannot be interrupted here.
final class OwnedLocalProcess {
    private let identifier: pid_t
    private let pipes: LocalProcessPipes
    private let output = ProcessOutputAccumulator()
    private var exitStatus: Int32?
    private var ownsIdentifier = true
    private var inputOffset = 0

    init(executableURL: URL, arguments: [String], environment: [String: String]) throws {
        let pipes = try LocalProcessPipes()
        self.identifier = try pipes.spawn(executableURL: executableURL, arguments: arguments, environment: environment)
        self.pipes = pipes
        pipes.closeChildEnds()
    }

    // Keep deadline, exit observation and group teardown ordered in one state loop.
    // swiftlint:disable:next cyclomatic_complexity
    func collect(
        input: Data, cancellation: LocalProcessCancellation, deadline: TimeInterval, timeout: TimeInterval
    ) throws -> String {
        var stopError: Error?
        var stopStarted: TimeInterval?
        var drainDeadline: TimeInterval?
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if stopError == nil {
                do { try cancellation.check(deadline: deadline, timeout: timeout) } catch {
                    stopError = error
                    stopStarted = now
                    signalGroup(SIGTERM)
                    pipes.close(.inputWrite)
                }
            }
            try observeExit()
            if exitStatus != nil, drainDeadline == nil {
                // Reap only after group teardown. Keeping the leader waitable reserves
                // its PID, so cleanup can never target a subsequently reused group ID.
                signalGroup(SIGKILL)
                drainDeadline = now + 0.25
            }
            if let stopStarted, now >= stopStarted + 0.25 { signalGroup(SIGKILL) }
            try pipes.readOutput(into: output)
            if stopError == nil { try pipes.writeInput(input, offset: &inputOffset) }
            if let stopError, now >= (stopStarted ?? now) + 0.5 { throw stopError }
            if let exitStatus, pipes.outputIsClosed || now >= (drainDeadline ?? now) {
                if let stopError { throw stopError }
                guard pipes.outputIsClosed else {
                    throw LocalProcessError.failed("Local process descendants kept output pipes open after exit.")
                }
                if let details = output.failureDescription(exitStatus: exitStatus) {
                    throw LocalProcessError.failed(details)
                }
                return output.stdout
            }
            try pipes.waitForActivity()
        }
    }

    private func observeExit() throws {
        guard exitStatus == nil else { return }
        var information = siginfo_t()
        let result = waitid(P_PID, id_t(identifier), &information, WEXITED | WNOHANG | WNOWAIT)
        if result == -1 {
            if errno == EINTR { return }
            // An external child reaper would invalidate ownership. Do not signal an
            // identifier that this runner can no longer prove belongs to its child.
            if errno == ECHILD { ownsIdentifier = false }
            throw LocalProcessError.systemCall("waitid", errno)
        }
        if information.si_pid == identifier {
            exitStatus = information.si_code == CLD_EXITED ? information.si_status : 128 + information.si_status
        }
    }

    private func signalGroup(_ signal: Int32) {
        guard ownsIdentifier else { return }
        _ = kill(-identifier, signal)
    }

    func finish() {
        guard ownsIdentifier else { return }
        signalGroup(SIGKILL)
        ownsIdentifier = false
        let identifier = self.identifier
        let reap: @Sendable () -> Void = {
            var status: Int32 = 0
            while waitpid(identifier, &status, 0) == -1 && errno == EINTR {}
        }
        if exitStatus != nil {
            reap()
        } else {
            // A kernel-blocked child cannot be synchronously reaped within a deadline.
            // The caller still returns; this reaper owns only the PID, never large I/O
            // buffers, and sends no later signals that could hit a reused identifier.
            DispatchQueue.global(qos: .utility).async(execute: reap)
        }
    }
}
#endif
