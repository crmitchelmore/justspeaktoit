import Foundation
import SpeakDesktop

package struct DesktopHostOwnedStartupSnapshot: Sendable {
    package enum Phase: Equatable, Sendable {
        case preparing, prepared, releasing, cleanupFailed, dispositionFailed, finished
    }
    package let requestID: UUID
    package let recordID: UUID
    package var phase = Phase.preparing
    package var attempt = 0
    package var token: DesktopPressCaptureToken?
    package var causes: [DesktopPressCaptureError] = []
    package var cleanupFailure: DesktopPressCaptureError?
    package var contractFailure: String?
    package var audioFailure: String?
    package var historyFailure: String?
}

package struct DesktopHostOwnedStartupDependency: Sendable {
    package let worker: any DesktopPressCaptureWorker
    package var deliverTicket: @Sendable (DesktopPressCaptureOwnedRelease) async -> Void = { _ in }
    package var beforeFile: @Sendable (DesktopHostOwnedFileStep) async -> Void = { _ in }
    package var afterFinish: @Sendable () throws -> Void = {}
}

struct DesktopHostOwnedStartupHandle: Sendable {
    let id: UUID
    let owner: DesktopHostOwnedStartup
    let abort: DesktopEventDispatcher<Void>
    let admission: Task<Void, Never>
    var abortRequested = false
    var observedAttempt = 0
}

actor DesktopHostOwnedStartupBarrier {
    private var ended = false
    private var waiter: CheckedContinuation<Void, Never>?
    func acknowledge() { ended = true; waiter?.resume(); waiter = nil }
    func value() async {
        if !ended { await withCheckedContinuation { waiter = $0 } }
    }
}

enum DesktopHostOwnedStartupNotice: Sendable {
    case failure(DesktopPressCaptureFailureEvent), barrier(DesktopHostOwnedStartupBarrier), overflow

    static func enqueue(_ pending: inout [Self], _ next: Self) {
        if case .failure = next {
            let count = pending.filter { if case .failure = $0 { return true }; return false }.count
            if count >= 3 {
                if !pending.contains(where: { if case .overflow = $0 { return true }; return false }) {
                    pending.append(.overflow)
                }
                return
            }
        }
        pending.append(next)
    }
}

/// Owns an abandoned/prepared startup, never an active recording or native adapter.
package actor DesktopHostOwnedStartup {
    package nonisolated let id: UUID
    private let identity: DesktopPressCaptureIdentity
    private let admission: DesktopPressCaptureAdmission
    private let limits: DesktopPressCaptureBufferLimits
    private let dependency: DesktopHostOwnedStartupDependency
    private let file: DesktopHostOwnedStartupFile
    private let permitOpening: @Sendable () async -> Bool
    private var changed: (@Sendable (DesktopHostOwnedStartupSnapshot) async -> Void)?
    private var state: DesktopHostOwnedStartupSnapshot
    private var lease: DesktopPressCaptureLease?
    private var ticket: DesktopPressCaptureOwnedRelease?
    private var inbox: DesktopEventDispatcher<DesktopHostOwnedStartupNotice>?
    private var operation: Task<Void, Never>?
    private var abortRequested = false
    private var admissionEnded = false
    private var dispositionEnded = false
    private var dispositionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        id: UUID, recordID: UUID, identity: DesktopPressCaptureIdentity, admission: DesktopPressCaptureAdmission,
        limits: DesktopPressCaptureBufferLimits, dependency: DesktopHostOwnedStartupDependency,
        file: DesktopHostOwnedStartupFile,
        permitOpening: @escaping @Sendable () async -> Bool,
        changed: @escaping @Sendable (DesktopHostOwnedStartupSnapshot) async -> Void
    ) {
        self.id = id
        self.identity = identity
        self.admission = admission
        self.limits = limits
        self.dependency = dependency
        self.file = file
        self.permitOpening = permitOpening
        self.changed = changed
        self.state = .init(requestID: id, recordID: recordID)
    }

    func start() async {
        do {
            try await file.prepare()
            let permitted = await permitOpening()
            if !permitted { abortRequested = true }
            if !abortRequested {
                let inbox = DesktopEventDispatcher<DesktopHostOwnedStartupNotice>(
                    coalescing: { DesktopHostOwnedStartupNotice.enqueue(&$0, $1) },
                    perform: { [self] in await receive($0) }
                )
                self.inbox = inbox
                let lease = DesktopPressCaptureLease.observingFailures(worker: dependency.worker) {
                    inbox.submit(.failure($0))
                }
                self.lease = lease
                let ticket = try await lease.beginOwned(identity: identity, admission: admission, limits: limits)
                await dependency.deliverTicket(ticket)
                self.ticket = ticket
                if let provisional = state.token, provisional != ticket.token {
                    state.contractFailure = "Owned startup received a mismatched provisional token."
                    abortRequested = true
                }
                state.token = ticket.token
            }
        } catch {
            state.contractFailure = "Startup failed: \(error.localizedDescription)"
            abortRequested = true
        }
        if Task.isCancelled { abortRequested = true }
        admissionEnded = true
        if abortRequested { beginRelease() } else { state.phase = .prepared; await notify() }
    }

    func abort() {
        guard state.phase != .finished else { return }
        abortRequested = true
        if admissionEnded { beginRelease() }
    }

    package func retryRelease() throws {
        guard state.phase == .cleanupFailed, operation == nil, let ticket else {
            throw DesktopPressCaptureError.invalidPhase
        }
        state.attempt += 1
        state.phase = .releasing
        state.cleanupFailure = nil
        let attempt = state.attempt
        operation = Task { [self] in
            await notify()
            await release(ticket, retry: true, attempt: attempt)
        }
    }

    package func retryDisposition() throws {
        guard state.phase == .dispositionFailed, operation == nil else {
            throw DesktopPressCaptureError.invalidPhase
        }
        state.phase = .releasing
        operation = Task { [self] in await dispose() }
    }

    package func snapshot() -> DesktopHostOwnedStartupSnapshot { state }
    package func waitForDisposition() async {
        if !dispositionEnded { await withCheckedContinuation { dispositionWaiters.append($0) } }
    }

    private func beginRelease() {
        guard operation == nil, state.phase != .cleanupFailed, state.phase != .dispositionFailed,
              state.phase != .finished else { return }
        state.phase = .releasing
        let ticket = ticket
        let attempt = state.attempt
        operation = Task { [self] in
            if let ticket { await release(ticket, retry: false, attempt: attempt) } else { await dispose() }
        }
    }

    private func release(_ ticket: DesktopPressCaptureOwnedRelease, retry: Bool, attempt: Int) async {
        var failure: DesktopPressCaptureError?
        do {
            if retry { try await ticket.retryRelease() } else { try await ticket.release() }
        } catch let error as DesktopPressCaptureError {
            failure = error
        } catch {
            state.contractFailure = "Unexpected release error: \(error.localizedDescription)"
            failure = .cleanupFailed(String(describing: error))
        }
        let barrier = DesktopHostOwnedStartupBarrier()
        inbox?.submit(.barrier(barrier))
        await barrier.value()
        guard state.attempt == attempt, state.token == ticket.token else { return }
        if let failure {
            state.cleanupFailure = failure
            state.phase = .cleanupFailed
            operation = nil
            await notify()
        } else {
            await dispose()
        }
    }

    func receive(_ notice: DesktopHostOwnedStartupNotice) async {
        if case .barrier(let barrier) = notice { await barrier.acknowledge(); return }
        guard state.phase != .finished else { return }
        switch notice {
        case .failure(let event):
            guard retainFailure(event) else { return }
        case .overflow:
            state.contractFailure = "Owned startup failure inbox overflow; causes may be incomplete."
        case .barrier: break
        }
        abortRequested = true
        if admissionEnded { beginRelease() }
        await notify()
    }

    private func retainFailure(_ event: DesktopPressCaptureFailureEvent) -> Bool {
        guard event.identity == identity, state.token == nil || state.token == event.token else { return false }
        if state.token == nil { state.token = event.token }
        if case .cleanupFailed = event.error, state.attempt > 0 {
            state.causes.removeAll { if case .cleanupFailed = $0 { return true }; return false }
        }
        if state.causes.count < 3 { state.causes.append(event.error) } else {
            state.contractFailure = "Owned startup failure inbox exceeded its canonical cause bound."
        }
        return true
    }

    private func dispose() async {
        let causes = state.causes.map { String(describing: $0) }
        let message = (causes + [state.contractFailure].compactMap { $0 }).joined(separator: " ")
        let saved = await file.dispose(
            message: message.isEmpty ? "Owned capture startup abandoned. Audio retained." : message
        )
        state.audioFailure = await file.audioFailure
        state.historyFailure = await file.historyFailure
        state.phase = saved ? .finished : .dispositionFailed
        operation = nil
        await notify()
        if saved {
            changed = nil
            ticket = nil
            lease = nil
            inbox = nil
            dispositionEnded = true
            let waiters = dispositionWaiters
            dispositionWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private func notify() async { await changed?(state) }
}

extension DesktopHostController {
    /// No production factory: only an explicitly injected worker can reach this seam.
    package func admitOwnedCaptureStartup(
        identity: DesktopPressCaptureIdentity, admission: DesktopPressCaptureAdmission,
        limits: DesktopPressCaptureBufferLimits, dependency: DesktopHostOwnedStartupDependency? = nil
    ) throws -> DesktopHostOwnedStartup {
        try Task.checkCancellation()
        guard let dependency else { throw DesktopHostError(message: "Owned capture startup is unavailable.") }
        guard canUseHistory, activeOperations == 0, ownedCaptureStartup == nil, !handsFreeMachine.isArmed,
              comparisonCapture == nil, comparisonTask == nil, comparisonAdmissionTask == nil,
              comparisonInitialization == nil, comparisonFinalization == nil, liveFinalisation == nil else {
            throw DesktopPressCaptureError.occupied
        }
        let id = UUID()
        var record = DesktopRecordingStore.Record(
            id: UUID(), audioFilename: id.uuidString + ".wav", modelIdentifier: identity.routeID
        )
        record.languageIdentifier = settings.configuration?.language
        record.failure = "Owned capture startup pending. Audio retained."
        let file = DesktopHostOwnedStartupFile(
            store: store, directory: directory.appendingPathComponent("History"),
            record: record, rate: identity.sampleRate,
            before: dependency.beforeFile, afterFinish: dependency.afterFinish
        )
        let owner = DesktopHostOwnedStartup(
            id: id, recordID: record.id, identity: identity, admission: admission,
            limits: limits, dependency: dependency, file: file,
            permitOpening: { [self] in await permitOwnedStartupOpening(id) },
            changed: { [self] snapshot in await ownedStartupChanged(snapshot) }
        )
        let abort = DesktopEventDispatcher<Void> { _ in await owner.abort() }
        beginBusyOperation()
        let task = Task { await owner.start() }
        ownedCaptureStartup = .init(id: id, owner: owner, abort: abort, admission: task)
        return owner
    }

    private func permitOwnedStartupOpening(_ id: UUID) -> Bool {
        !closed && ownedCaptureStartup?.id == id && ownedCaptureStartup?.abortRequested == false
    }

    func requestOwnedStartupAbort() {
        ownedCaptureStartup?.abortRequested = true
        ownedCaptureStartup?.abort.submit(())
    }

    func ownedStartupChanged(_ snapshot: DesktopHostOwnedStartupSnapshot) {
        guard ownedCaptureStartup?.id == snapshot.requestID,
              snapshot.attempt >= (ownedCaptureStartup?.observedAttempt ?? 0) else { return }
        ownedCaptureStartup?.observedAttempt = snapshot.attempt
        if snapshot.phase == .finished {
            ownedCaptureStartup = nil
            finishBusyOperation()
        }
        if !closed, snapshot.phase != .prepared {
            let failures = snapshot.causes.map { String(describing: $0) }
                + [snapshot.contractFailure, snapshot.audioFailure, snapshot.historyFailure].compactMap { $0 }
            update(failures.isEmpty ? "Owned capture startup abandoned. Audio retained."
                : failures.joined(separator: " "), state: 0)
        }
    }
}
