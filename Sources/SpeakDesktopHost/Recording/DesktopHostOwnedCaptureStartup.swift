import Foundation
import SpeakDesktop

package struct DesktopHostOwnedStartupSnapshot: Sendable {
    package enum Phase: Equatable, Sendable {
        case preparing, prepared, adopting, recording, releasing, cleanupFailed, dispositionFailed, finished
    }
    package let requestID: UUID
    package let recordID: UUID
    package var phase = Phase.preparing
    package var attempt = 0
    package var revision: UInt64 = 0
    package var recording: DesktopHostOwnedRecording?
    package var captureStatus: String?
    package var persistenceFailure: String?
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
    package var beforePCM: @Sendable (Int) throws -> Void = { _ in }
    package var beforeOwnedDelivery: @Sendable () async -> Void = {}
}

struct DesktopHostOwnedStartupHandle: Sendable {
    let id: UUID
    let owner: DesktopHostOwnedStartup
    let abort: DesktopEventDispatcher<Void>
    let admission: Task<Void, Never>
    var abortRequested = false
    var observedAttempt = 0
    var observedRevision: UInt64 = 0
    var phase = DesktopHostOwnedStartupSnapshot.Phase.preparing
    var recording: DesktopHostOwnedRecording?
    var promotion: Task<Void, Never>?
    var stop: Task<Void, Never>?
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

/// Retains one injected startup and its optional owned recording through durable disposition.
package actor DesktopHostOwnedStartup {
    package nonisolated let id: UUID
    let identity: DesktopPressCaptureIdentity
    let admission: DesktopPressCaptureAdmission
    private let limits: DesktopPressCaptureBufferLimits
    let dependency: DesktopHostOwnedStartupDependency
    let file: DesktopHostOwnedStartupFile
    let permitOpening: @Sendable () async -> Bool
    let acceptRecording: @Sendable (DesktopHostOwnedStartupSnapshot) async -> Bool
    private var changed: (@Sendable (DesktopHostOwnedStartupSnapshot) async -> Void)?
    var state: DesktopHostOwnedStartupSnapshot
    var lease: DesktopPressCaptureLease?
    var ticket: DesktopPressCaptureOwnedRelease?
    var capture = DesktopHostOwnedRecordingState()
    var inbox: DesktopEventDispatcher<DesktopHostOwnedStartupNotice>?
    private var operation: Task<Void, Never>?
    var abortRequested = false
    private var admissionEnded = false
    private var dispositionEnded = false
    private var dispositionWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        id: UUID, recordID: UUID, identity: DesktopPressCaptureIdentity, admission: DesktopPressCaptureAdmission,
        limits: DesktopPressCaptureBufferLimits, dependency: DesktopHostOwnedStartupDependency,
        file: DesktopHostOwnedStartupFile,
        permitOpening: @escaping @Sendable () async -> Bool,
        acceptRecording: @escaping @Sendable (DesktopHostOwnedStartupSnapshot) async -> Bool,
        changed: @escaping @Sendable (DesktopHostOwnedStartupSnapshot) async -> Void
    ) {
        self.id = id
        self.identity = identity
        self.admission = admission
        self.limits = limits
        self.dependency = dependency
        self.file = file
        self.permitOpening = permitOpening
        self.acceptRecording = acceptRecording
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
        state.recording = nil
        state.captureStatus = nil
        capture.promotion?.cancel()
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

    func beginRelease() {
        guard operation == nil, state.phase != .cleanupFailed, state.phase != .dispositionFailed,
              state.phase != .finished else { return }
        state.phase = .releasing
        state.recording = nil
        let ticket = ticket
        let attempt = state.attempt
        operation = Task { [self] in
            if capture.promotion != nil { await notify() }
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
        await capture.promotion?.value
        let barrier = DesktopHostOwnedStartupBarrier()
        inbox?.submit(.barrier(barrier))
        await barrier.value()
        await drainPCMFailures()
        guard state.attempt == attempt, state.token == ticket.token else { return }
        if let failure {
            state.cleanupFailure = failure
            state.captureStatus = nil
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
        state.recording = nil
        state.captureStatus = nil
        capture.promotion?.cancel()
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
        if capture.stoppedNormally, capture.dispositionCaptured == nil, !(await permitOpening()) {
            abortRequested = true
        }
        let causes = state.causes.map { String(describing: $0) }
        let message = (causes + [state.contractFailure, capture.failure].compactMap { $0 }).joined(separator: " ")
        let captured = capture.dispositionCaptured ?? (capture.stoppedNormally && !abortRequested && message.isEmpty)
        capture.dispositionCaptured = captured
        let saved = await file.dispose(
            message: message.isEmpty ? "Owned capture startup abandoned. Audio retained." : message,
            captured: captured
        )
        state.audioFailure = await file.audioFailure
        state.historyFailure = await file.historyFailure
        state.captureStatus = await file.record().failure
        state.phase = saved ? .finished : .dispositionFailed
        operation = nil
        await notify()
        if saved {
            changed = nil
            ticket = nil
            lease = nil
            inbox = nil
            capture = DesktopHostOwnedRecordingState()
            dispositionEnded = true
            let waiters = dispositionWaiters
            dispositionWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func notify() async {
        state.revision &+= 1
        await changed?(state)
    }
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
            acceptRecording: { [self] snapshot in await acceptOwnedRecording(snapshot) },
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
              snapshot.attempt >= (ownedCaptureStartup?.observedAttempt ?? 0),
              snapshot.revision > (ownedCaptureStartup?.observedRevision ?? 0) else { return }
        ownedCaptureStartup?.observedAttempt = snapshot.attempt
        ownedCaptureStartup?.observedRevision = snapshot.revision
        ownedCaptureStartup?.phase = snapshot.phase
        let recording = closed || ownedCaptureStartup?.abortRequested == true ? nil : snapshot.recording
        ownedCaptureStartup?.recording = recording
        if snapshot.phase == .finished {
            ownedCaptureStartup = nil
            finishBusyOperation()
        }
        if !closed, snapshot.phase != .prepared, snapshot.phase != .adopting, snapshot.phase != .recording {
            let failures = snapshot.causes.map { String(describing: $0) }
                + [snapshot.contractFailure, snapshot.persistenceFailure, snapshot.audioFailure,
                   snapshot.historyFailure].compactMap { $0 }
            update(failures.isEmpty ? snapshot.captureStatus ?? "Owned capture startup abandoned. Audio retained."
                : failures.joined(separator: " "), state: 0)
        }
    }
}
