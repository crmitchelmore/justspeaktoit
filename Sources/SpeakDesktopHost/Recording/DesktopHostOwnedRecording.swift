import Foundation
import SpeakDesktop

package struct DesktopHostOwnedRecording: Equatable, Sendable {
    package let requestID: UUID
    package let recordID: UUID
    package let token: DesktopPressCaptureToken
    package let identity: DesktopPressCaptureIdentity
}

package struct DesktopHostOwnedPCMMemory: Equatable, Sendable {
    package let blockBytes: Int

    package init(sampleRate: Int) throws {
        guard sampleRate == 16_000 || sampleRate == 24_000 else {
            throw DesktopPressCaptureError.invalidConfiguration
        }
        self.blockBytes = sampleRate / 10 * MemoryLayout<Int16>.size
    }

    /// Context.receive makes one Data copy while the aligned scratch block is alive.
    package func retainedUpperBound(relayBudgetBytes: Int) -> Int {
        relayBudgetBytes + 2 * blockBytes
    }

    func deliver(
        _ data: Data, before: @Sendable (Int) -> Void,
        receive: (UnsafePointer<Int16>, Int) -> Void
    ) {
        for offset in stride(from: 0, to: data.count, by: blockBytes) {
            let bytes = min(blockBytes, data.count - offset)
            let count = bytes / MemoryLayout<Int16>.size
            withUnsafeTemporaryAllocation(of: Int16.self, capacity: count) { scratch in
                data.withUnsafeBytes { source in
                    UnsafeMutableRawBufferPointer(scratch).copyMemory(
                        from: UnsafeRawBufferPointer(rebasing: source[offset..<(offset + bytes)])
                    )
                }
                before(bytes)
                if let base = scratch.baseAddress { receive(base, count) }
            }
        }
    }
}

struct DesktopHostOwnedRecordingState {
    var promotion: Task<Void, Never>?
    var failures: DesktopEventDispatcher<DesktopHostOwnedPCMNotice>?
    var stoppedNormally = false
    var dispositionCaptured: Bool?
    var failure: String?
}

enum DesktopHostOwnedPCMNotice: Sendable {
    case failure(String), barrier(DesktopHostOwnedStartupBarrier)
}

extension DesktopHostOwnedStartup {
    func requestRecording() {
        guard state.phase == .prepared, !abortRequested, capture.promotion == nil else { return }
        state.phase = .adopting
        capture.promotion = Task { [self] in await promote() }
    }

    private func promote() async {
        do {
            guard let lease, let ticket else { throw DesktopPressCaptureError.invalidPhase }
            await notify()
            try checkPromotion()
            try await lease.reserve(ticket.token, identity: identity, admission: admission)
            try await lease.waitUntilReady(ticket.token)
            try checkPromotion()
            let failures = DesktopEventDispatcher<DesktopHostOwnedPCMNotice>(
                coalescing: {
                    // One latched failure and at most two promotion/release barriers.
                    precondition($0.count < 3)
                    $0.append($1)
                },
                perform: { [self] notice in await receivePCM(notice) }
            )
            capture.failures = failures
            await dependency.beforeOwnedDelivery()
            try checkPromotion()
            let sink = try await file.delivery(
                token: ticket.token, identity: identity, before: dependency.beforePCM,
                failure: { failures.submit(.failure($0)) }
            )
            guard await permitOpening() else { throw CancellationError() }
            try checkPromotion()
            try await lease.adoptDelivery(
                ticket.token, identity: identity, admission: admission, onPCMDelivery: sink
            )
            await drainAdoptionFailures()
            try checkPromotion()
            guard await permitOpening() else { throw CancellationError() }
            try checkPromotion()
            state.recording = .init(
                requestID: id, recordID: state.recordID, token: ticket.token, identity: identity
            )
            state.phase = .recording
            state.revision &+= 1
            guard await acceptRecording(state) else { throw CancellationError() }
            guard state.phase == .recording, !abortRequested else { return }
        } catch {
            if !(error is CancellationError) { state.contractFailure = "Owned adoption failed: \(error)" }
            abort()
        }
    }

    private func checkPromotion() throws {
        try Task.checkCancellation()
        guard state.phase == .adopting, !abortRequested, capture.failure == nil else {
            throw CancellationError()
        }
    }

    private func receivePCM(_ notice: DesktopHostOwnedPCMNotice) async {
        switch notice {
        case .failure(let message):
            guard state.phase != .finished else { return }
            capture.failure = "PCM persistence failed: \(message)"
            state.persistenceFailure = capture.failure
            abort()
            await notify()
        case .barrier(let barrier):
            await barrier.acknowledge()
        }
    }

    func drainPCMFailures() async {
        guard let failures = capture.failures else { return }
        let barrier = DesktopHostOwnedStartupBarrier()
        failures.submit(.barrier(barrier))
        await barrier.value()
    }

    private func drainAdoptionFailures() async {
        let barrier = DesktopHostOwnedStartupBarrier()
        inbox?.submit(.barrier(barrier))
        await barrier.value()
        await drainPCMFailures()
    }

    package func waitForRecordingOutcome() async -> DesktopHostOwnedStartupSnapshot {
        await waitForDisposition()
        return state
    }

    func stopRecording() {
        guard state.phase == .recording, !abortRequested else { return }
        capture.stoppedNormally = true
        state.captureStatus = "Finishing captured audio..."
        beginRelease()
    }
}

extension DesktopHostController {
    package var ownedRecording: DesktopHostOwnedRecording? {
        guard !closed, let slot = ownedCaptureStartup, !slot.abortRequested, slot.phase == .recording else {
            return nil
        }
        return slot.recording
    }

    func acceptOwnedRecording(_ snapshot: DesktopHostOwnedStartupSnapshot) -> Bool {
        guard !closed, let slot = ownedCaptureStartup, slot.id == snapshot.requestID,
              !slot.abortRequested, slot.phase == .adopting, snapshot.phase == .recording,
              snapshot.recording?.requestID == slot.id, snapshot.recording?.token == snapshot.token else {
            return false
        }
        ownedStartupChanged(snapshot)
        return ownedCaptureStartup?.recording == snapshot.recording
    }

    package func requestOwnedRecording(requestID: UUID) throws {
        try Task.checkCancellation()
        guard !closed, var slot = ownedCaptureStartup, slot.id == requestID,
              !slot.abortRequested, slot.phase == .prepared, slot.promotion == nil else {
            throw DesktopPressCaptureError.invalidPhase
        }
        slot.phase = .adopting
        let owner = slot.owner
        slot.promotion = Task { await owner.requestRecording() }
        ownedCaptureStartup = slot
    }

    package func requestOwnedRecordingStop(requestID: UUID) throws {
        guard !closed, let slot = ownedCaptureStartup, slot.id == requestID,
              !slot.abortRequested, slot.phase == .recording else {
            throw DesktopPressCaptureError.invalidPhase
        }
        ownedCaptureStartup?.phase = .releasing
        ownedCaptureStartup?.recording = nil
        // A single control event; PCM never crosses this dispatcher.
        let owner = slot.owner
        ownedCaptureStartup?.stop = Task { await owner.stopRecording() }
    }
}
