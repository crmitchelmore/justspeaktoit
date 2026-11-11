import Foundation

/// A single bounded drain delivers in admission order without invoking user code under the state lock.
/// Closing fences new PCM; settling joins delivery admitted before that fence, including an active sink.
package final class DesktopPressCapturePCMRelay: @unchecked Sendable {
    private enum Phase { case rolling, reserved, attached, closing, closed }
    private struct Receipt {
        var accepted = false
        var failure: DesktopPressCaptureError?
        var drain = false
    }
    private let lock = NSLock()
    private let delivery = DispatchQueue(label: "jsti.press-capture-delivery")
    private let joined = DispatchGroup()
    private let limits: DesktopPressCaptureBufferLimits
    private let onFailure: @Sendable (DesktopPressCaptureError) -> Void
    private let recovery: (@Sendable (DesktopPressCapturePCMBuffer) -> Void)?
    private var phase = Phase.rolling
    private var buffered = Data()
    private var beforeReservationSampleCount = 0
    private var inFlightBytes = 0
    private var draining = false
    private var storedFailure: DesktopPressCaptureError?
    private var sink: (@Sendable (DesktopPressCapturePCMBuffer) -> Void)?

    package init(
        limits: DesktopPressCaptureBufferLimits,
        onFailure: @escaping @Sendable (DesktopPressCaptureError) -> Void
    ) {
        self.limits = limits
        self.onFailure = onFailure
        self.recovery = nil
    }

    init(
        limits: DesktopPressCaptureBufferLimits,
        recovery: @escaping @Sendable (DesktopPressCapturePCMBuffer) -> Void,
        onFailure: @escaping @Sendable (DesktopPressCaptureError) -> Void
    ) {
        self.limits = limits
        self.onFailure = onFailure
        self.recovery = recovery
    }

    package var bufferedBytes: Int { lock.withLock { buffered.count + inFlightBytes } }
    package var failure: DesktopPressCaptureError? { lock.withLock { storedFailure } }

    @discardableResult
    package func receive(_ data: Data) -> Bool {
        let receipt = lock.withLock { () -> Receipt in
            guard phase != .closed, phase != .closing else { return Receipt() }
            if let error = append(data) {
                if recovery != nil {
                    let first = storedFailure == nil
                    if first { storedFailure = error }
                    return Receipt(failure: first ? error : nil)
                }
                storedFailure = error
                return Receipt(failure: error, drain: fence())
            }
            return Receipt(accepted: true, drain: claimDrain())
        }
        if receipt.drain { delivery.async { self.drain() } }
        if let failure = receipt.failure { onFailure(failure) }
        return receipt.accepted
    }

    package func reserve() throws {
        try lock.withLock {
            guard phase == .rolling else { throw DesktopPressCaptureError.invalidPhase }
            beforeReservationSampleCount = buffered.count / 2
            phase = .reserved
        }
    }

    package func attach(_ sink: @escaping @Sendable (Data) -> Void) throws {
        try attachDelivery { sink($0.data) }
    }

    func attachDelivery(_ sink: @escaping @Sendable (DesktopPressCapturePCMBuffer) -> Void) throws {
        let needsDrain = try lock.withLock {
            guard phase == .reserved else { throw DesktopPressCaptureError.invalidPhase }
            self.sink = sink
            phase = .attached
            return claimDrain()
        }
        if needsDrain { delivery.async { self.drain() } }
    }

    package func close() {
        let needsDrain = lock.withLock { fence() }
        if needsDrain { delivery.async { self.drain() } }
    }

    package func fail(_ error: DesktopPressCaptureError) {
        if recovery != nil { recordWorkerFailure(error); return }
        let publish = lock.withLock {
            guard phase != .closed, phase != .closing else { return false }
            storedFailure = error
            _ = fence()
            return true
        }
        if publish { onFailure(error) }
    }

    func recordWorkerFailure(_ error: DesktopPressCaptureError) {
        let publish = lock.withLock {
            guard storedFailure == nil else { return false }
            storedFailure = error
            if recovery == nil { _ = fence() }
            return true
        }
        if publish { onFailure(error) }
    }

    package func settleDelivery() async throws {
        guard lock.withLock({ phase == .closed || phase == .closing }) else {
            throw DesktopPressCaptureError.invalidPhase
        }
        await withCheckedContinuation { done in
            joined.notify(queue: .global()) { done.resume() }
        }
    }

    private func append(_ data: Data) -> DesktopPressCaptureError? {
        guard data.count.isMultiple(of: 2) else { return .invalidPCM }
        if phase == .rolling, recovery == nil {
            appendRolling(data)
        } else {
            guard data.count <= limits.reservedBytes - buffered.count - inFlightBytes else {
                return .startupOverflow
            }
            buffered.append(data)
        }
        return nil
    }

    private func fence() -> Bool {
        if phase != .attached, phase != .closing, phase != .closed, let recovery {
            sink = recovery
            phase = .closing
            let needsDrain = claimDrain()
            if !draining { phase = .closed; sink = nil }
            return needsDrain
        }
        if phase == .attached || phase == .closing {
            phase = .closing
            if !draining {
                phase = .closed
                sink = nil
            }
            return false
        } else {
            phase = .closed
            buffered.removeAll()
            beforeReservationSampleCount = 0
            sink = nil
        }
        return false
    }

    private func claimDrain() -> Bool {
        guard phase == .attached || phase == .closing, !buffered.isEmpty, !draining else { return false }
        draining = true
        joined.enter()
        return true
    }

    private func drain() {
        while let next = lock.withLock({ takeDelivery() }) {
            next.sink(next.pcm)
            lock.withLock { inFlightBytes = 0 }
        }
        joined.leave()
    }

    private func takeDelivery() -> (sink: @Sendable (DesktopPressCapturePCMBuffer) -> Void,
                                   pcm: DesktopPressCapturePCMBuffer)? {
        guard !buffered.isEmpty, let sink else {
            draining = false
            if phase == .closing { phase = .closed; self.sink = nil }
            return nil
        }
        let pcm = DesktopPressCapturePCMBuffer(
            data: buffered, beforeReservationSampleCount: beforeReservationSampleCount
        )
        buffered = Data()
        beforeReservationSampleCount = 0
        inFlightBytes = pcm.data.count
        return (sink, pcm)
    }

    private func appendRolling(_ data: Data) {
        if data.count >= limits.preRollBytes {
            buffered = Data(data.suffix(limits.preRollBytes))
        } else {
            let excess = buffered.count - (limits.preRollBytes - data.count)
            if excess > 0 { buffered.removeFirst(excess) }
            buffered.append(data)
        }
    }
}
