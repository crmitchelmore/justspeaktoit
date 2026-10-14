import Foundation

/// Ownership only: gesture recognition/timers stay with their canonical state machines.
/// No native adapter is installed by this type. An external capture must also honor the lease
/// arbitration before opening a microphone; an `.idle` admission is not OS ownership proof.
package actor DesktopPressCaptureLease {
    private struct Run {
        let token: DesktopPressCaptureToken
        let identity: DesktopPressCaptureIdentity
        let relay: DesktopPressCapturePCMRelay
        var phase = DesktopPressCapturePhase.pending
        var ready = false
        var cleanupFailure: DesktopPressCaptureError?
        var reportedRelayFailure = false
    }

    private let worker: any DesktopPressCaptureWorker
    private let onFailureEvent: @Sendable (DesktopPressCaptureFailureEvent) -> Void
    private var run: Run?
    private var operation: Task<Void, Never>?
    private var operationGeneration: UInt64 = 0
    private var closed = false
    package private(set) var failure: DesktopPressCaptureError?

    package init(
        worker: any DesktopPressCaptureWorker,
        onFailure: @escaping @Sendable (DesktopPressCaptureError) -> Void
    ) {
        self.init(worker: worker, onFailureEvent: { onFailure($0.error) })
    }

    package init(
        worker: any DesktopPressCaptureWorker,
        onFailureEvent: @escaping @Sendable (DesktopPressCaptureFailureEvent) -> Void
    ) {
        self.worker = worker
        self.onFailureEvent = onFailureEvent
    }

    package var phase: DesktopPressCapturePhase { run?.phase ?? .idle }

    package func begin(
        identity: DesktopPressCaptureIdentity, admission: DesktopPressCaptureAdmission,
        limits: DesktopPressCaptureBufferLimits
    ) throws -> DesktopPressCaptureToken {
        try Task.checkCancellation()
        guard !closed else { throw DesktopPressCaptureError.closed }
        if let refusal = admission.refusal { throw DesktopPressCaptureError.refused(refusal) }
        guard run == nil else { throw DesktopPressCaptureError.occupied }
        try identity.validate()
        let token = DesktopPressCaptureToken()
        let relay = DesktopPressCapturePCMRelay(limits: limits) { [weak self] error in
            let event = DesktopPressCaptureFailureEvent(token: token, identity: identity, error: error)
            Task { await self?.captureFailed(event) }
        }
        run = Run(token: token, identity: identity, relay: relay)
        failure = nil
        operationGeneration &+= 1
        operation = Task {
            guard run?.token == token else { return }
            guard run?.phase != .closing, !closed else { run = nil; return }
            do {
                try await worker.open(
                    id: token.id, identity: identity, receive: { _ = relay.receive($0) },
                    onFailure: { relay.fail(.captureFailed($0)) }
                )
                await opened(token, error: nil)
            } catch {
                await opened(token, error: DesktopPressCaptureFailureEvent(
                    token: token, identity: identity, error: .openFailed(String(describing: error))
                ))
            }
        }
        return token
    }

    package func reserve(
        _ token: DesktopPressCaptureToken, identity: DesktopPressCaptureIdentity,
        admission: DesktopPressCaptureAdmission
    ) throws {
        try validate(token, identity: identity, admission: admission)
        guard var current = run, current.phase == .pending || current.phase == .open else {
            throw DesktopPressCaptureError.invalidPhase
        }
        do { try current.relay.reserve() } catch {
            cancel(token)
            throw error
        }
        current.phase = .reserved
        run = current
    }

    package func waitUntilReady(_ token: DesktopPressCaptureToken) async throws {
        try await withTaskCancellationHandler {
            guard run?.token == token else { throw DesktopPressCaptureError.staleLease }
            await operation?.value
            try Task.checkCancellation()
            guard let current = run, current.token == token, current.phase != .closing else {
                throw failure ?? DesktopPressCaptureError.staleLease
            }
            guard current.ready else { throw DesktopPressCaptureError.notReady }
        } onCancel: {
            Task { await self.cancel(token) }
        }
    }

    package func adopt(
        _ token: DesktopPressCaptureToken, identity: DesktopPressCaptureIdentity,
        admission: DesktopPressCaptureAdmission, sink: @escaping @Sendable (Data) -> Void
    ) throws {
        try validate(token, identity: identity, admission: admission)
        guard var current = run, current.phase == .reserved else { throw DesktopPressCaptureError.invalidPhase }
        guard current.ready else { throw DesktopPressCaptureError.notReady }
        do { try current.relay.attach(sink) } catch {
            cancel(token)
            throw error
        }
        current.phase = .adopted
        run = current
    }

    /// Idempotent for late events. A reserved/adopted lease still belongs to its explicit owner.
    /// The owner must cancel it on abandonment or session stop; dropping a token never releases IO.
    package func cancel(_ token: DesktopPressCaptureToken) {
        guard var current = run, current.token == token, current.phase != .closing else { return }
        current.relay.close()
        current.phase = .closing
        run = current
        if current.ready { enqueueClose(token) }
    }

    package func shutdown() {
        closed = true
        if let token = run?.token { cancel(token) }
    }

    /// Waits for real IO completion. It deliberately has no success-shaped timeout.
    /// A failed close retains the closing lease and requires explicit retry.
    package func settle() async throws {
        var observed: UInt64
        repeat {
            if let current = run, let error = current.relay.failure {
                captureFailed(DesktopPressCaptureFailureEvent(
                    token: current.token, identity: current.identity, error: error
                ))
            }
            observed = operationGeneration
            await operation?.value
        } while observed != operationGeneration
        if let error = run?.cleanupFailure { throw error }
    }

    package func retryClose(_ token: DesktopPressCaptureToken) throws {
        guard var current = run, current.token == token, current.cleanupFailure != nil else {
            throw DesktopPressCaptureError.invalidPhase
        }
        current.cleanupFailure = nil
        run = current
        enqueueClose(token)
    }

    private func validate(
        _ token: DesktopPressCaptureToken, identity: DesktopPressCaptureIdentity,
        admission: DesktopPressCaptureAdmission
    ) throws {
        guard let current = run, current.token == token, current.phase != .closing else {
            throw DesktopPressCaptureError.staleLease
        }
        do {
            try Task.checkCancellation()
            guard current.identity == identity else { throw DesktopPressCaptureError.identityChanged }
            if let refusal = admission.refusal { throw DesktopPressCaptureError.refused(refusal) }
        } catch {
            cancel(token)
            throw error
        }
    }

    private func opened(_ token: DesktopPressCaptureToken, error: DesktopPressCaptureFailureEvent?) async {
        guard var current = run, current.token == token else { return }
        current.ready = true
        if let error {
            current.relay.close()
            current.phase = .closing
            failure = error.error
            onFailureEvent(error)
        }
        if current.phase == .pending { current.phase = .open }
        run = current
        if current.phase == .closing { await closeWorker(token) }
    }

    private func captureFailed(_ event: DesktopPressCaptureFailureEvent) {
        guard var current = run, current.token == event.token, !current.reportedRelayFailure else { return }
        current.reportedRelayFailure = true
        run = current
        failure = event.error
        onFailureEvent(event)
        cancel(event.token)
    }

    private func enqueueClose(_ token: DesktopPressCaptureToken) {
        let previous = operation
        operationGeneration &+= 1
        operation = Task {
            await previous?.value
            await closeWorker(token)
        }
    }

    private func closeWorker(_ token: DesktopPressCaptureToken) async {
        guard let current = run, current.token == token else { return }
        if let error = current.relay.failure {
            captureFailed(DesktopPressCaptureFailureEvent(token: token, identity: current.identity, error: error))
        }
        do {
            try await current.relay.settleDelivery()
            try await worker.close(id: token.id)
            if run?.token == token { run = nil }
        } catch {
            let error = DesktopPressCaptureError.cleanupFailed(String(describing: error))
            run?.cleanupFailure = error
            failure = error
            onFailureEvent(DesktopPressCaptureFailureEvent(token: token, identity: current.identity, error: error))
        }
    }
}
