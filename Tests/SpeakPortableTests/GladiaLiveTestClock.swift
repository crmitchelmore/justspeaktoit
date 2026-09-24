import Foundation
@testable import SpeakCore

/// A clock that only moves when the test advances it. It can also hold the
/// thread that arms a given deadline, which stalls every effect the client
/// queued behind that registration.
final class GladiaManualClock: @unchecked Sendable {
    private struct Entry {
        let due: TimeInterval
        let delay: TimeInterval
        let action: @Sendable () -> Void
    }

    private struct Hold {
        let delay: TimeInterval
        let entered: @Sendable () -> Void
        let gate: DispatchSemaphore
    }

    private let lock = NSLock()
    private var now: TimeInterval = 0
    private var entries: [Entry] = []
    private var delays: [TimeInterval] = []
    private var watchers: [(delay: TimeInterval, action: @Sendable () -> Void)] = []
    private var holds: [Hold] = []

    var scheduledDelays: [TimeInterval] { lock.withLock { delays } }

    var scheduler: GladiaLiveClient.Scheduler {
        { [self] seconds, action in
            let (matched, hold) = lock.withLock { () -> ([@Sendable () -> Void], Hold?) in
                entries.append(Entry(due: now + seconds, delay: seconds, action: action))
                delays.append(seconds)
                let hits = watchers.filter { $0.delay == seconds }.map(\.action)
                watchers.removeAll { $0.delay == seconds }
                guard let index = holds.firstIndex(where: { $0.delay == seconds }) else { return (hits, nil) }
                return (hits, holds.remove(at: index))
            }
            matched.forEach { $0() }
            if let hold {
                hold.entered()
                hold.gate.wait()
            }
        }
    }

    /// The thread that next arms a deadline of exactly `delay` records it,
    /// reports that it is held, then blocks until `gate` is signalled.
    func holdScheduling(
        _ delay: TimeInterval, entered: @escaping @Sendable () -> Void, until gate: DispatchSemaphore
    ) {
        lock.withLock { holds.append(Hold(delay: delay, entered: entered, gate: gate)) }
    }

    /// Runs `action` once, when a deadline of exactly `delay` is next armed.
    func whenScheduled(_ delay: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        lock.withLock { watchers.append((delay, action)) }
    }

    func count(of delay: TimeInterval) -> Int { lock.withLock { delays.filter { $0 == delay }.count } }

    /// Moves time forward and fires every deadline now due, in due order.
    func advance(by seconds: TimeInterval) {
        let due = lock.withLock { () -> [Entry] in
            now += seconds
            let ready = entries.filter { $0.due <= now }.sorted { $0.due < $1.due }
            entries.removeAll { $0.due <= now }
            return ready
        }
        due.forEach { $0.action() }
    }
}
