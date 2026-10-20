import Foundation
import SpeakCore

/// Advancing a named pending sleep, not wall time, drives every timing test.
actor PolishClock {
    struct Suspension {
        let duration: Duration
        let gate: PolishSleepGate
    }
    private var suspended: [Suspension] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    var count: Int { suspended.count }

    func sleep(_ duration: Duration) async throws {
        let gate = PolishSleepGate()
        suspended.append(.init(duration: duration, gate: gate))
        let ready = observers.filter { $0.0 < suspended.count }
        observers.removeAll { $0.0 < suspended.count }
        ready.forEach { $0.1.resume() }
        try await withTaskCancellationHandler { try await gate.wait() } onCancel: {
            gate.settle(.failure(CancellationError()))
        }
    }

    func pending(_ index: Int) async -> Duration {
        if suspended.count <= index {
            await withCheckedContinuation { observers.append((index, $0)) }
        }
        return suspended[index].duration
    }

    func advance(_ index: Int) {
        suspended[index].gate.settle(.success(()))
    }

    func releaseAll() {
        suspended.forEach { $0.gate.settle(.failure(CancellationError())) }
    }
}

final class PolishSleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let result = lock.withLock { () -> Result<Void, Error>? in
                if let outcome { return outcome }
                waiter = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func settle(_ result: Result<Void, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard outcome == nil else { return nil }
            outcome = result
            defer { waiter = nil }
            return waiter
        }
        pending?.resume(with: result)
    }
}
/// Deliberately ignores cancellation, so identity fencing is exercised rather
/// than accidentally depending on a well-behaved provider.
actor PolishClient {
    struct Request {
        let text: String
        let continuation: CheckedContinuation<String, Error>
    }
    private var requests: [Request] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    var count: Int { requests.count }

    func complete(_ text: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            requests.append(.init(text: text, continuation: continuation))
            let ready = observers.filter { $0.0 < requests.count }
            observers.removeAll { $0.0 < requests.count }
            ready.forEach { $0.1.resume() }
        }
    }

    func request(_ index: Int) async -> String {
        if requests.count <= index { await withCheckedContinuation { observers.append((index, $0)) } }
        return requests[index].text
    }

    func succeed(_ index: Int, _ text: String) { requests[index].continuation.resume(returning: text) }
    func fail(_ index: Int) { requests[index].continuation.resume(throwing: PolishFixtureError.failed) }
}

enum PolishFixtureError: LocalizedError {
    case failed
    var errorDescription: String? { "Injected cleanup request failed." }
}
