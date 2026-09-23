import Foundation

/// Native WebSocket state whose destruction did not complete stays owned here.
///
/// `jsti_websocket_destroy` refuses to free a socket while WinHTTP may still
/// call into its context, and documents that destruction can be retried. A
/// failed release therefore keeps its socket and retained callback context in
/// this queue, which retries it with capped backoff and whenever a new
/// connection asks for admission. Once `limit` failed releases are outstanding,
/// new connections are refused instead of accumulating native state. Nothing is
/// freed without a successful native destroy and nothing is silently dropped.
final class WinHTTPReleaseQueue: @unchecked Sendable {
    /// Returns true once the native state and its context have been freed.
    typealias Release = @Sendable () -> Bool

    private struct Entry {
        let release: Release
        var delay: TimeInterval
        var inFlight: Bool
    }

    static let shared = WinHTTPReleaseQueue()

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let limit: Int
    private let initialDelay: TimeInterval
    private let maximumDelay: TimeInterval
    private var failed: [UUID: Entry] = [:]

    init(
        limit: Int = 4, initialDelay: TimeInterval = 0.25, maximumDelay: TimeInterval = 30,
        queue: DispatchQueue = DispatchQueue(label: "JustSpeakToIt.winhttp.release", qos: .utility)
    ) {
        self.limit = limit
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.queue = queue
    }

    /// Failed releases whose native state is still owned by this queue.
    var outstanding: Int { lock.withLock { failed.count } }

    /// Schedules a retry of every outstanding release, then reports whether a
    /// new native socket may be created. Retries run asynchronously, so a slot
    /// freed by one is available to a later admission.
    func admit() -> Bool {
        let (ids, admitted) = lock.withLock { (Array(failed.keys), failed.count < limit) }
        ids.forEach { id in queue.async { self.attempt(id) } }
        return admitted
    }

    /// Runs the first release attempt off the caller's thread.
    func release(_ release: @escaping Release) {
        queue.async {
            guard !release() else { return }
            let id = UUID()
            self.lock.withLock {
                self.failed[id] = Entry(release: release, delay: self.initialDelay, inFlight: false)
            }
            self.reportAndSchedule(id, after: self.initialDelay)
        }
    }

    private func attempt(_ id: UUID) {
        let release = lock.withLock { () -> Release? in
            guard var entry = failed[id], !entry.inFlight else { return nil }
            entry.inFlight = true
            failed[id] = entry
            return entry.release
        }
        guard let release else { return }
        if release() {
            lock.withLock { _ = failed.removeValue(forKey: id) }
            return
        }
        let delay = lock.withLock { () -> TimeInterval in
            guard var entry = failed[id] else { return initialDelay }
            entry.inFlight = false
            entry.delay = min(maximumDelay, entry.delay * 2)
            failed[id] = entry
            return entry.delay
        }
        reportAndSchedule(id, after: delay)
    }

    private func reportAndSchedule(_ id: UUID, after delay: TimeInterval) {
        let message = "Windows WebSocket cleanup did not complete; it remains owned and will be retried.\n"
        FileHandle.standardError.write(Data(message.utf8))
        queue.asyncAfter(deadline: .now() + delay) { self.attempt(id) }
    }
}
