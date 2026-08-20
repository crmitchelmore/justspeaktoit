import Foundation

/// Runs recording toggles in arrival order, including across suspension points
/// such as the microphone-permission prompt.
///
/// Main-actor isolation alone is not enough because actors are re-entrant while
/// an operation awaits. Ownership stays reserved for the next waiter until it
/// finishes, so a new caller cannot overtake an already queued tap.
@MainActor
final class WatchRecordingToggleSerialiser {
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run(_ operation: @MainActor () async -> Void) async {
        await self.acquire()
        defer { self.release() }
        await operation()
    }

    private func acquire() async {
        guard self.isRunning else {
            self.isRunning = true
            return
        }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    private func release() {
        guard !self.waiters.isEmpty else {
            self.isRunning = false
            return
        }
        self.waiters.removeFirst().resume()
    }
}
