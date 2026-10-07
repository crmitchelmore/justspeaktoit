import Foundation

@testable import SpeakApp

// Fakes for `HotKeyPressPrimerTests`.

final class PrimerFakeCapture {
    let keyDownUptime: TimeInterval
    var isClosed = false

    init(keyDownUptime: TimeInterval) {
        self.keyDownUptime = keyDownUptime
    }
}

/// Scheduled actions run only when the test fires them.
struct PrimerScheduledEntry {
    let delay: TimeInterval
    let action: @MainActor () -> Void
    var isCancelled = false
}

final class PrimerManualScheduler {
    var entries: [PrimerScheduledEntry] = []

    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> HotKeyPressPrimerTimer {
        entries.append(PrimerScheduledEntry(delay: delay, action: action))
        let index = entries.count - 1
        return HotKeyPressPrimerTimer { [weak self] in self?.entries[index].isCancelled = true }
    }

    /// Fires every pending action scheduled with `delay`.
    @MainActor
    func fire(delay: TimeInterval) {
        for index in entries.indices where entries[index].delay == delay && !entries[index].isCancelled {
            entries[index].isCancelled = true
            entries[index].action()
        }
    }

    var pendingDelays: [TimeInterval] {
        entries.filter { !$0.isCancelled }.map(\.delay)
    }
}

final class PrimerTestEnvironment {
    var isEligible = true
    var keepsAlive = false
    var opened: [PrimerFakeCapture] = []
    var closed: [PrimerFakeCapture] = []
    var failOpen = false
    /// When set, opens wait until the test resumes them.
    var holdOpens = false
    var pendingOpens: [CheckedContinuation<Void, Never>] = []
    let scheduler = PrimerManualScheduler()

    func resumeOpens() {
        let pending = pendingOpens
        pendingOpens = []
        pending.forEach { $0.resume() }
    }
}
