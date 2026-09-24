import Foundation

/// Owns a closed native WebSocket from the moment its connection hands it over
/// until `jsti_websocket_destroy` has freed it.
///
/// Destruction cancels the socket, joins its worker and drains WinHTTP
/// callbacks, so it runs off the caller's thread on one serial queue. It can
/// also fail while WinHTTP may still call into the socket's context; the native
/// API then requires the socket and context to be kept and destruction retried.
/// Every release counts toward `limit` from the moment it is handed over,
/// whether queued, running or failed, so a slow or failing destruction refuses
/// new connections before they create native state instead of letting a burst
/// of short-lived connections queue sockets and callback contexts without bound.
/// A failed release is retried with capped backoff, and sooner when a new
/// connection asks for admission. Each release has at most one attempt queued
/// or running and one retry timer, however often admission is requested.
/// Nothing is freed without a successful native destroy and nothing is dropped.
///
/// Live connections are not counted, so concurrent streams are never refused
/// or cut short here. A caller with one live socket at a time never has more
/// than `limit` native sockets.
final class WinHTTPReleaseQueue: @unchecked Sendable {
    /// Returns true once the native state and its context have been freed.
    typealias Release = @Sendable () -> Bool
    /// Runs work after a delay in seconds. Tests inject one to hold retries.
    typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    private enum State {
        /// One attempt is on the release queue.
        case queued
        /// One attempt is destroying the native state.
        case running
        /// The last attempt failed; its timer or an admission queues the next.
        case waiting
    }

    private struct Entry {
        let release: Release
        var state = State.queued
        var delay: TimeInterval
        var timerArmed = false
        var failed = false
    }

    static let shared = WinHTTPReleaseQueue()

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let schedule: Scheduler
    private let limit: Int
    private let initialDelay: TimeInterval
    private let maximumDelay: TimeInterval
    private var entries: [UInt64: Entry] = [:]
    private var nextID: UInt64 = 0

    init(
        limit: Int = 4, initialDelay: TimeInterval = 0.25, maximumDelay: TimeInterval = 30,
        queue: DispatchQueue = DispatchQueue(label: "JustSpeakToIt.winhttp.release", qos: .utility),
        schedule: Scheduler? = nil
    ) {
        self.limit = limit
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.queue = queue
        self.schedule = schedule ?? { delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) }
    }

    /// Releases handed over whose native state is not yet freed: queued,
    /// running or failed.
    var outstanding: Int { lock.withLock { entries.count } }

    /// Reports whether a new native socket may be created, and brings forward
    /// the retry of each failed release not already queued or running. Neither
    /// waits for a destruction.
    func admit() -> Bool {
        let (admitted, retries) = lock.withLock { () -> (Bool, [UInt64]) in
            let retries = entries.filter { $0.value.state == .waiting }.keys.sorted()
            retries.forEach { entries[$0]?.state = .queued }
            return (entries.count < limit, retries)
        }
        retries.forEach { id in queue.async { self.attempt(id) } }
        return admitted
    }

    /// Takes ownership of a closed socket's release. It counts toward `limit`
    /// before this returns; every attempt runs off the caller's thread.
    func release(_ release: @escaping Release) {
        let id = lock.withLock { () -> UInt64 in
            nextID += 1
            entries[nextID] = Entry(release: release, delay: initialDelay)
            return nextID
        }
        queue.async { self.attempt(id) }
    }

    /// Runs on the release queue, once for each time the entry was queued.
    private func attempt(_ id: UInt64) {
        let release = lock.withLock { () -> Release? in
            guard entries[id]?.state == .queued else { return nil }
            entries[id]?.state = .running
            return entries[id]?.release
        }
        guard let release else { return }
        if release() {
            lock.withLock { entries[id] = nil }
            return
        }
        let (delay, firstFailure) = lock.withLock { () -> (TimeInterval?, Bool) in
            guard var entry = entries[id] else { return (nil, false) }
            // An armed timer from an earlier failure already covers this one.
            let delay = entry.timerArmed ? nil : entry.delay
            let firstFailure = !entry.failed
            entry.state = .waiting
            entry.failed = true
            entry.timerArmed = true
            entry.delay = min(maximumDelay, entry.delay * 2)
            entries[id] = entry
            return (delay, firstFailure)
        }
        if firstFailure {
            let message = "Windows WebSocket cleanup did not complete; it remains owned and will be retried.\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
        if let delay { schedule(delay) { self.retryDue(id) } }
    }

    /// A backoff timer fired. An attempt already queued or running absorbs it
    /// and arms the next timer if it fails.
    private func retryDue(_ id: UInt64) {
        let due = lock.withLock { () -> Bool in
            guard var entry = entries[id] else { return false }
            let due = entry.state == .waiting
            entry.timerArmed = false
            if due { entry.state = .queued }
            entries[id] = entry
            return due
        }
        if due { queue.async { self.attempt(id) } }
    }
}
