#if os(iOS)
import Foundation

/// Frozen completion facts, never transcript content or a mutable "latest" pointer.
struct TranscriptReadyNotificationInput: Equatable {
    let historyID: UUID?
    var transcriptIsEmpty = false
    var failed = false
    var isForeground = false
    var keyboardInserted = false
    var matchingResultActivity = false

    var isEligible: Bool {
        self.historyID != nil && !self.transcriptIsEmpty && !self.failed
            && !self.isForeground && !self.keyboardInserted && !self.matchingResultActivity
    }
}

/// All notification effects are injected. No authorization request is made by scheduling.
@MainActor
struct TranscriptReadyNotificationCenter {
    var authorized: () async -> Bool
    var requestAlertPermission: () async -> Bool
    var enqueue: (UUID) async throws -> Void
    var pendingIdentifiers: () async -> [String]
    var removePending: ([String]) -> Void
}

/// Serializes eligibility/claim/enqueue. A durable claim precedes enqueue and is
/// retained after errors: best-effort at-most-once scheduling, never delivery proof.
@MainActor
final class TranscriptReadyNotificationCoordinator {
    static let shared = TranscriptReadyNotificationCoordinator.live()

    private let center: TranscriptReadyNotificationCenter
    private let isEnabled: () -> Bool
    private let writeEnabled: (Bool) -> Void
    private let claim: (UUID, Date) throws -> Bool
    private let forget: (Set<UUID>) throws -> Void
    private let now: () -> Date
    private var generation = 0
    private var queue: [TranscriptReadyNotificationInput] = []
    private var workers: [Int: Task<Void, Never>] = [:]
    private var enqueuing: Set<UUID> = []
    private var removal: Task<Void, Never>?

    init(
        center: TranscriptReadyNotificationCenter,
        isEnabled: @escaping () -> Bool,
        writeEnabled: @escaping (Bool) -> Void,
        claim: @escaping (UUID, Date) throws -> Bool,
        forget: @escaping (Set<UUID>) throws -> Void = { _ in },
        now: @escaping () -> Date = Date.init
    ) {
        self.center = center
        self.isEnabled = isEnabled
        self.writeEnabled = writeEnabled
        self.claim = claim
        self.forget = forget
        self.now = now
    }

    /// Called only by an intentional Settings toggle, never launch or capture.
    @discardableResult
    func setEnabledFromUser(_ enabled: Bool) async -> Bool {
        if !enabled {
            let observedGeneration = self.generation
            self.writeEnabled(false)
            if observedGeneration == self.generation { self.disable() }
            return false
        }
        let observedGeneration = self.generation
        // Finish opt-out removal before a later opt-in may enqueue anything.
        await self.removal?.value
        guard observedGeneration == self.generation else { return false }
        let allowed = await self.center.requestAlertPermission()
        guard observedGeneration == self.generation else { return false }
        self.writeEnabled(allowed)
        if !allowed, observedGeneration == self.generation { self.disable() }
        return allowed
    }

    /// Also connected to the local setting, so programmatic opt-out invalidates awaits.
    func disable() {
        self.workers[self.generation]?.cancel()
        self.generation += 1
        self.queue.removeAll()
        let previousRemoval = self.removal
        self.removal = Task {
            await previousRemoval?.value
            let identifiers = await self.center.pendingIdentifiers().filter {
                $0.hasPrefix(TranscriptReadyNotificationRoute.requestPrefix)
            }
            self.center.removePending(identifiers)
        }
    }

    func submit(_ input: TranscriptReadyNotificationInput) {
        guard self.isEnabled(), input.isEligible else { return }
        self.queue.append(input)
        let observedGeneration = self.generation
        guard self.workers[observedGeneration] == nil else { return }
        self.workers[observedGeneration] = Task {
            await self.removal?.value
            await self.drain(generation: observedGeneration)
            self.workers.removeValue(forKey: observedGeneration)
        }
    }

    private func drain(generation: Int) async {
        while !Task.isCancelled, generation == self.generation, !self.queue.isEmpty {
            let input = self.queue.removeFirst()
            guard self.isEnabled(), input.isEligible, let identifier = input.historyID else { continue }
            let authorized = await self.center.authorized()
            guard !Task.isCancelled, generation == self.generation, self.isEnabled(), authorized else { continue }
            do {
                // A previous generation may still be finishing this stable ID.
                // Never let its late cleanup remove a newer request for that ID.
                guard !self.enqueuing.contains(identifier), try self.claim(identifier, self.now()) else { continue }
                self.enqueuing.insert(identifier)
                defer {
                    // An uncooperative enqueue can finish after opt-out. No newer
                    // generation may enqueue this ID until its cleanup has finished.
                    if generation != self.generation || !self.isEnabled() {
                        self.center.removePending([TranscriptReadyNotificationRoute.requestIdentifier(for: identifier)])
                    }
                    self.enqueuing.remove(identifier)
                }
                try await self.center.enqueue(identifier)
            } catch {
                // No retries, capture failures, transcript logs or claim rollback.
            }
        }
    }

    func forgetClaims(for identifiers: Set<UUID>) {
        try? self.forget(identifiers)
    }

    /// Test/lifecycle seam; scheduling callers do not wait for notification effects.
    func waitUntilIdle() async {
        for worker in self.workers.values { await worker.value }
        await self.removal?.value
    }
}
#endif
