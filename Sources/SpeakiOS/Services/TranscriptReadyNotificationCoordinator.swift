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
    var removeDelivered: ([String]) -> Void = { _ in }
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
    private let historyExists: (UUID) -> Bool
    private var generation = 0
    /// Optional alerts admit at most 64 queued/processing candidates, coalesced
    /// by History ID. A stalled OS operation cannot retain unlimited completions.
    static let maximumAdmittedCandidates = 64
    private struct Candidate {
        let token = UUID()
        let input: TranscriptReadyNotificationInput
    }
    private var queue: [Candidate] = []
    private var processing: [UUID: UUID] = [:]
    private var invalidated: Set<UUID> = []
    private var workers: [Int: Task<Void, Never>] = [:]
    private var enqueuing: Set<UUID> = []
    private var removal: Task<Void, Never>?

    init(
        center: TranscriptReadyNotificationCenter,
        isEnabled: @escaping () -> Bool,
        writeEnabled: @escaping (Bool) -> Void,
        claim: @escaping (UUID, Date) throws -> Bool,
        forget: @escaping (Set<UUID>) throws -> Void = { _ in },
        now: @escaping () -> Date = Date.init,
        historyExists: @escaping (UUID) -> Bool = { _ in true }
    ) {
        self.center = center
        self.isEnabled = isEnabled
        self.writeEnabled = writeEnabled
        self.claim = claim
        self.forget = forget
        self.now = now
        self.historyExists = historyExists
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
        let hasWorkerCapacity = self.workers.count < Self.maximumAdmittedCandidates
            || self.workers[self.generation] != nil
        guard self.isEnabled(), input.isEligible, let identifier = input.historyID,
              !self.queue.contains(where: { $0.input.historyID == identifier }),
              !self.processing.values.contains(identifier),
              self.queue.count + self.processing.count < Self.maximumAdmittedCandidates,
              hasWorkerCapacity else { return }
        self.queue.append(Candidate(input: input))
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
            let candidate = self.queue.removeFirst()
            let input = candidate.input
            guard self.isEnabled(), input.isEligible, let identifier = input.historyID else { continue }
            self.processing[candidate.token] = identifier
            defer {
                self.processing.removeValue(forKey: candidate.token)
                self.invalidated.remove(candidate.token)
            }
            let authorized = await self.center.authorized()
            guard !Task.isCancelled, generation == self.generation, self.isEnabled(), authorized,
                  !self.invalidated.contains(candidate.token), self.historyExists(identifier) else { continue }
            do {
                // A previous generation may still be finishing this stable ID.
                // Never let its late cleanup remove a newer request for that ID.
                guard !self.enqueuing.contains(identifier), try self.claim(identifier, self.now()) else { continue }
                self.enqueuing.insert(identifier)
                defer {
                    // An uncooperative enqueue can finish after opt-out. No newer
                    // generation may enqueue this ID until its cleanup has finished.
                    if generation != self.generation || !self.isEnabled()
                        || self.invalidated.contains(candidate.token) || !self.historyExists(identifier) {
                        self.removeRequest(for: identifier)
                    }
                    self.enqueuing.remove(identifier)
                }
                try await self.center.enqueue(identifier)
            } catch {
                // No retries, capture failures, transcript logs or claim rollback.
            }
        }
    }

    /// Explicit durable local History deletion retires only those rows' notices.
    /// Tokens cover awaits; the exact-row existence check also covers deletion
    /// before a completed capture submits its frozen result.
    func retireNotifications(for identifiers: Set<UUID>) {
        self.queue.removeAll { candidate in
            candidate.input.historyID.map { identifiers.contains($0) } ?? false
        }
        self.invalidated.formUnion(self.processing.compactMap { token, identifier in
            identifiers.contains(identifier) ? token : nil
        })
        for identifier in identifiers { self.removeRequest(for: identifier) }
        try? self.forget(identifiers)
    }

    private func removeRequest(for identifier: UUID) {
        let requests = [TranscriptReadyNotificationRoute.requestIdentifier(for: identifier)]
        self.center.removePending(requests)
        self.center.removeDelivered(requests)
    }

    /// Reconcile persisted opt-out on launch, even if an earlier process died
    /// after writing false but before its asynchronous removal ran. No prompt.
    func reconcilePersistedPreference() {
        if !self.isEnabled() { self.disable() }
    }

    /// Test/lifecycle seam; scheduling callers do not wait for notification effects.
    func waitUntilIdle() async {
        for worker in self.workers.values { await worker.value }
        await self.removal?.value
    }
}
#endif
