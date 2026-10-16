import Foundation
import SpeakCore
import SpeakDesktop

/// Explicit composition evidence, never inferred from a preference or catalogue entry.
/// makeWorker constructs an owner without opening a device on the calling actor.
package struct DesktopHostOwnedDictationCapability: Sendable {
    package let capability: DesktopPressCaptureCapability
    package let permission: DesktopPressCapturePermission
    package let makeWorker: @Sendable () -> any DesktopPressCaptureQuiescingWorker

    package init(
        capability: DesktopPressCaptureCapability, permission: DesktopPressCapturePermission,
        makeWorker: @escaping @Sendable () -> any DesktopPressCaptureQuiescingWorker
    ) {
        self.capability = capability
        self.permission = permission
        self.makeWorker = makeWorker
    }
}

package struct DesktopHostRecordingInput: Sendable {
    let key: String
    let azureEndpoint: String
    let vocabulary: [String]
}

package struct DesktopHostOwnedDictationRequest<Platform: DesktopHostPlatform>: Sendable {
    let record: DesktopRecordingStore.Record
    let identity: DesktopPressCaptureIdentity
    let profile: DesktopProfileSession
    let input: DesktopHostRecordingInput
    let target: Platform.InsertionTarget?
    let textOutput: Platform.TextOutputOptions
    let trigger: HotKeySessionTrigger
    let configuration: DesktopConfiguration?
    let tailSeconds: TimeInterval
    let live: DesktopLiveSession?
}

private enum OwnedDictationNotice: Sendable {
    case failure(DesktopPressCaptureFailureEvent)
    case pcmFailure(String)
    case barrier(DesktopHostOwnedStartupBarrier)
    case overflow

    static func enqueue(_ queue: inout [Self], _ next: Self) {
        if case .barrier = next { queue.append(next); return }
        if queue.count < 4 { queue.append(next) } else if !queue.contains(where: {
            if case .overflow = $0 { return true }; return false
        }) { queue.append(.overflow) }
    }
}

private final class OwnedDictationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: String?
    private var earlyStop = false
    var cancellation: String? { lock.withLock { reason } }
    var recoveryOnly: Bool { lock.withLock { reason != nil || earlyStop } }
    func abort(_ message: String) { lock.withLock { if reason == nil { reason = message } } }
    func stopBeforeAdoption() { lock.withLock { earlyStop = true } }
}

/// One real dictation file/context and one release ticket. Unsafe retirement keeps all
/// four alive; a terminal value exists only after retirement and the failure barrier.
package actor DesktopHostOwnedDictationSession<Platform: DesktopHostPlatform> {
    package enum Phase: Equatable, Sendable { case opening, recording, stopping, cleanupFailed, finished }
    package nonisolated let request: DesktopHostOwnedDictationRequest<Platform>
    private let file: PCMRecordingFile
    private let capability: DesktopHostOwnedDictationCapability
    private let onFailure: @Sendable () -> Void
    private let onSilence: @Sendable () -> Void
    private let beforePCM: @Sendable (Int) throws -> Void
    private nonisolated let control = OwnedDictationControl()
    private var lease: DesktopPressCaptureLease?
    private var ticket: DesktopPressCaptureOwnedRelease?
    private var inbox: DesktopEventDispatcher<OwnedDictationNotice>?
    private var context: DesktopCaptureContext?
    private var opening: Task<Void, Never>?
    private var ending: Task<DesktopHostController<Platform>.StoppedRecording?, Never>?
    private var terminal: DesktopHostController<Platform>.StoppedRecording?
    private var stopped = false
    private var adopted = false
    private var causes: [String] = []
    package private(set) var phase = Phase.opening
    package private(set) var cleanupFailure: String?
    package private(set) var finishCount = 0
    var readyForDictation: Bool { phase == .recording && !stopped && control.cancellation == nil }

    init(
        request: DesktopHostOwnedDictationRequest<Platform>, file: PCMRecordingFile,
        capability: DesktopHostOwnedDictationCapability,
        onFailure: @escaping @Sendable () -> Void, onSilence: @escaping @Sendable () -> Void,
        beforePCM: @escaping @Sendable (Int) throws -> Void = { _ in }
    ) {
        self.request = request
        self.file = file
        self.capability = capability
        self.onFailure = onFailure
        self.onSilence = onSilence
        self.beforePCM = beforePCM
    }

    func start() async -> Bool {
        let control = control
        let onFailure = onFailure
        return await withTaskCancellationHandler {
            if opening == nil { opening = Task { await self.open() } }
            await opening?.value
            return phase == .recording && !stopped && control.cancellation == nil
        } onCancel: {
            control.abort("Recording startup cancelled. Audio retained.")
            onFailure()
        }
    }

    nonisolated func abort(_ message: String) { control.abort(message) }

    func stop(retry: Bool = false) async -> DesktopHostController<Platform>.StoppedRecording? {
        if let terminal { return terminal }
        if let ending { return await ending.value }
        guard phase != .cleanupFailed || retry else { return nil }
        if !adopted { control.stopBeforeAdoption() }
        stopped = true
        phase = .stopping
        let operation = Task { await self.release(retry: retry) }
        ending = operation
        let result = await operation.value
        ending = nil
        return result
    }

    private func open() async {
        guard !stopped, control.cancellation == nil else { return }
        let inbox = DesktopEventDispatcher<OwnedDictationNotice>(
            coalescing: { OwnedDictationNotice.enqueue(&$0, $1) },
            perform: { [self] in await receive($0) }
        )
        self.inbox = inbox
        let admission = DesktopPressCaptureAdmission(
            enabled: true, capability: capability.capability, permission: capability.permission, owner: .idle
        )
        do {
            if let refusal = admission.refusal { throw DesktopPressCaptureError.refused(refusal) }
            let memory = try DesktopHostOwnedPCMMemory(sampleRate: request.identity.sampleRate)
            let configuration = request.configuration
            let silence = configuration?.enabled("silenceDetectionEnabled") == true
                ? DictationSilenceMonitor(
                    threshold: configuration?.number("silenceThreshold") ?? DictationSilencePolicy.defaultThreshold,
                    duration: configuration?.number("silenceDuration") ?? DictationSilencePolicy.defaultDuration
                ) : nil
            let context = DesktopCaptureContext(
                file: file, live: request.live, sampleRate: request.identity.sampleRate,
                silence: silence, onSilence: onSilence,
                onFailure: { inbox.submit(.pcmFailure($0)) }
            )
            self.context = context
            let beforePCM = beforePCM
            let control = control
            let lease = DesktopPressCaptureLease.recoveringOwned(
                worker: capability.makeWorker(),
                recoveryDelivery: { context.receiveRecovery($0.data) },
                onFailureEvent: { inbox.submit(.failure($0)) }
            )
            self.lease = lease
            let limits = try DesktopPressCaptureBufferLimits(
                preRollFrames: request.identity.sampleRate, reservedFrames: request.identity.sampleRate * 2
            )
            let ticket = try await lease.beginOwned(identity: request.identity, admission: admission, limits: limits)
            self.ticket = ticket
            guard !stopped, control.cancellation == nil else { return }
            try await lease.reserve(ticket.token, identity: request.identity, admission: admission)
            try await lease.waitUntilReady(ticket.token)
            guard !stopped, control.cancellation == nil else { return }
            try await lease.adoptDelivery(
                ticket.token, identity: request.identity, admission: admission
            ) { delivery in
                guard delivery.token == ticket.token, delivery.identity == ticket.identity else {
                    inbox.submit(.pcmFailure("Owned dictation received a stale PCM delivery."))
                    return
                }
                memory.deliver(delivery.data, before: { bytes in
                    do { try beforePCM(bytes) } catch { context.fail(String(describing: error)) }
                }) { samples, count in
                    if control.recoveryOnly {
                        context.receiveRecovery(Data(bytes: samples, count: count * MemoryLayout<Int16>.size))
                    } else {
                        context.receive(samples, count: count)
                    }
                }
            }
            await barrier()
            if !stopped, control.cancellation == nil, causes.isEmpty { adopted = true; phase = .recording }
        } catch {
            retain("Owned dictation startup failed: \(error)")
            stopped = true
            onFailure()
        }
    }

    private func release(retry: Bool) async -> DesktopHostController<Platform>.StoppedRecording? {
        // Open may still own a partially allocated native run. Its acknowledgement is
        // mandatory even after cancellation; no WAV/context is released ahead of it.
        await opening?.value
        if let ticket {
            do {
                if retry { try await ticket.retryRelease() } else { try await ticket.release() }
                cleanupFailure = nil
            } catch {
                await barrier()
                let message = "Owned dictation retirement failed: \(error)"
                retain(message)
                cleanupFailure = message
                phase = .cleanupFailed
                return nil
            }
        }
        await barrier()
        if !adopted, causes.isEmpty, control.cancellation == nil {
            retain("Recording stopped before capture was ready. Audio retained.")
        }
        var record = request.record
        var duration: TimeInterval = 0
        finishCount += 1
        do { duration = try file.finish() } catch { retain("Audio finalization failed: \(error)") }
        if let cancellation = control.cancellation { retain(cancellation) }
        if !causes.isEmpty {
            record.failure = causes.joined(separator: " ")
            if let live = request.live {
                let snapshot = live.cancel()
                if adopted {
                    record.result = DesktopHostRecordingStop.liveResult(
                        snapshot.text, model: record.modelIdentifier, duration: duration
                    )
                }
            }
        }
        let terminal = DesktopHostController<Platform>.StoppedRecording(
            record: record, duration: file.isDigitalSilence ? 0 : duration, target: request.target,
            live: request.live, profile: request.profile, textOutput: request.textOutput, input: request.input
        )
        self.terminal = terminal
        phase = .finished
        self.ticket = nil
        lease = nil
        context = nil
        inbox = nil
        return terminal
    }

    private func barrier() async {
        guard let inbox else { return }
        let barrier = DesktopHostOwnedStartupBarrier()
        inbox.submit(.barrier(barrier))
        await barrier.value()
    }

    private func receive(_ notice: OwnedDictationNotice) async {
        if case .barrier(let barrier) = notice { await barrier.acknowledge(); return }
        guard phase != .finished else { return }
        switch notice {
        case .failure(let event):
            guard event.identity == request.identity, ticket == nil || event.token == ticket?.token else { return }
            retain(String(describing: event.error))
        case .pcmFailure(let message): retain("PCM persistence failed: \(message)")
        case .overflow: retain("Owned dictation failure inbox overflow; diagnostics may be incomplete.")
        case .barrier: return
        }
        stopped = true
        onFailure()
    }

    private func retain(_ message: String) {
        guard !causes.contains(message) else { return }
        if causes.count < 8 {
            causes.append(message)
        } else if causes.last != "Further owned dictation errors omitted." {
            causes.append("Further owned dictation errors omitted.")
        }
    }
}
