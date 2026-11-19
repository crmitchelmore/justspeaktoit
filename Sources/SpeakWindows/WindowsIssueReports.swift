import Foundation
import CWindowsSupport
import SpeakDesktopHost

// Each shared admission gets its own native handle; no callback can select a
// later preview through a process-global "current report".
final class WindowsIssueReportBridge: @unchecked Sendable {
    fileprivate let handle: OpaquePointer

    private init?() {
        guard let handle = jsti_issue_report_create() else { return nil }
        self.handle = handle
    }

    deinit { jsti_issue_report_release(handle) }

    static func actions() -> DesktopHostIssueReportActions? {
        guard let bridge = WindowsIssueReportBridge() else { return nil }
        return .init(
            present: { bridge.present($0) },
            dismiss: { _ in jsti_issue_report_retire(bridge.handle) },
            chooseDestination: { await bridge.choose($0) },
            copy: { try await bridge.copy($0) },
            open: { await bridge.open($0) }
        )
    }

    private func present(_ preview: DesktopHostIssueReportPreview) -> Bool {
        let report = preview.report
        return withIssueReportStrings([
            preview.ticket.uuidString, report.title, report.body, report.jsonString,
            report.issueURL?.absoluteString ?? "", preview.status?.message ?? ""
        ]) { values in
            jsti_issue_report_present(
                handle, values[0], values[1], values[2], values[3], values[4], values[5],
                preview.includesDiagnostics ? 1 : 0, preview.isExporting ? 1 : 0,
                preview.isOpening || preview.isCopying ? 1 : 0
            ) == 0
        }
    }

    private func copy(_ body: String) async throws {
        let pending = WindowsIssueReportPending(owner: self)
        let accepted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let completion = WindowsIssueReportCompletion.accepted(continuation)
                pending.register(completion) { context in
                    withIssueReportStrings([pending.identifier, body]) { values in
                        jsti_issue_report_copy(handle, values[0], values[1], issueReportResult, context)
                    }
                }
            }
        } onCancel: { pending.cancel() }
        guard accepted else { throw WindowsNativeError(message: "Could not copy the draft.") }
    }

    private func choose(_ filename: String) async -> DesktopHostIssueReportDestination {
        let pending = WindowsIssueReportPending(owner: self)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let completion = WindowsIssueReportCompletion.destination(continuation)
                pending.register(completion) { context in
                    withIssueReportStrings([pending.identifier, filename]) { values in
                        jsti_issue_report_choose(handle, values[0], values[1], issueReportResult, context)
                    }
                }
            }
        } onCancel: { pending.cancel() }
    }

    private func open(_ url: URL) async -> Bool {
        let pending = WindowsIssueReportPending(owner: self)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let completion = WindowsIssueReportCompletion.accepted(continuation)
                pending.register(completion) { context in
                    withIssueReportStrings([pending.identifier, url.absoluteString]) { values in
                        jsti_issue_report_open(handle, values[0], values[1], issueReportResult, context)
                    }
                }
            }
        } onCancel: { pending.cancel() }
    }
}

// Native registration is queue-only and never invokes the callback inline.
// The brief lock closes cancel-before-registration without blocking the UI,
// an actor, OS operation or callback completion.
private final class WindowsIssueReportPending: @unchecked Sendable {
    let identifier = UUID().uuidString
    private let owner: WindowsIssueReportBridge
    private let lock = NSLock()
    private var cancelled = false
    private var registered = false

    init(owner: WindowsIssueReportBridge) { self.owner = owner }

    func register(
        _ completion: WindowsIssueReportCompletion,
        start: (UnsafeMutableRawPointer) -> Int32
    ) {
        lock.lock()
        if cancelled {
            lock.unlock()
            completion.finish(1, value: nil)
            return
        }
        let context = Unmanaged.passRetained(completion).toOpaque()
        let accepted = start(context) == 0
        registered = accepted
        lock.unlock()
        if !accepted {
            Unmanaged<WindowsIssueReportCompletion>.fromOpaque(context).release()
            completion.finish(2, value: nil)
        }
    }

    func cancel() {
        let shouldCancel = lock.withLock {
            cancelled = true
            return registered
        }
        if shouldCancel { identifier.withCString { jsti_issue_report_cancel(owner.handle, $0) } }
    }
}

private final class WindowsIssueReportCompletion: @unchecked Sendable {
    private enum Result {
        case destination(CheckedContinuation<DesktopHostIssueReportDestination, Never>)
        case accepted(CheckedContinuation<Bool, Never>)
    }
    private let result: Result
    private init(_ result: Result) { self.result = result }

    static func destination(
        _ continuation: CheckedContinuation<DesktopHostIssueReportDestination, Never>
    ) -> WindowsIssueReportCompletion { .init(.destination(continuation)) }

    static func accepted(_ continuation: CheckedContinuation<Bool, Never>) -> WindowsIssueReportCompletion {
        .init(.accepted(continuation))
    }

    func finish(_ code: Int32, value: String?) {
        switch result {
        case .destination(let continuation):
            if code == 0, let value, !value.isEmpty {
                continuation.resume(returning: .selected(URL(fileURLWithPath: value)))
            } else { continuation.resume(returning: code == 1 ? .cancelled : .failed) }
        case .accepted(let continuation): continuation.resume(returning: code == 0)
        }
    }
}

private func issueReportResult(_ code: Int32, _ value: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let completion = Unmanaged<WindowsIssueReportCompletion>.fromOpaque(context).takeRetainedValue()
    completion.finish(code, value: value.map { String(cString: $0) })
}

private func withIssueReportStrings<Value>(
    _ values: [String], _ body: ([UnsafePointer<CChar>]) -> Value
) -> Value {
    let buffers = values.map { value -> UnsafeMutablePointer<CChar> in
        let bytes = Array(value.utf8CString)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
        buffer.initialize(from: bytes, count: bytes.count)
        return buffer
    }
    defer { buffers.forEach { $0.deallocate() } }
    return body(buffers.map { UnsafePointer($0) })
}

// Tracks only unfinished operations, using private per-operation identities.
// A Task cannot enter the actor before its handle is attached. Cancellation
// before attachment therefore cannot resurrect untracked chooser/export work.
final class WindowsIssueReportTasks: @unchecked Sendable {
    private final class Slot: @unchecked Sendable {
        let identifier = UUID()
        let ticket: UUID
        var task: Task<Void, Never>?
        var ready: CheckedContinuation<Bool, Never>?
        var attached = false
        var retired = false
        init(ticket: UUID) { self.ticket = ticket }
    }
    private let lock = NSLock()
    private var slots: [UUID: Slot] = [:]
    private var closed = false

    func submit(ticket: UUID, operation: @escaping @Sendable () async -> Void) {
        let slot = Slot(ticket: ticket)
        guard lock.withLock({
            guard !closed else { return false }
            slots[slot.identifier] = slot
            return true
        }) else { return }
        let task = Task { [self] in
            defer { finish(slot) }
            guard await isAttached(slot), !Task.isCancelled else { return }
            await operation()
        }
        var waiter: CheckedContinuation<Bool, Never>?
        let cancelled = lock.withLock {
            let valid = !closed && !slot.retired && slots[slot.identifier] === slot
            slot.attached = true
            if valid { slot.task = task }
            waiter = slot.ready
            slot.ready = nil
            return !valid
        }
        if cancelled { task.cancel() }
        waiter?.resume(returning: !cancelled)
    }

    private func isAttached(_ slot: Slot) async -> Bool {
        await withCheckedContinuation { continuation in
            let immediate: Bool? = lock.withLock {
                if closed || slot.retired || slots[slot.identifier] !== slot { return false }
                if slot.attached { return true }
                slot.ready = continuation
                return nil
            }
            if let immediate { continuation.resume(returning: immediate) }
        }
    }

    private func finish(_ slot: Slot) {
        lock.withLock {
            slot.retired = true
            slot.task = nil
            if slots[slot.identifier] === slot { slots.removeValue(forKey: slot.identifier) }
        }
    }

    func cancel(ticket: UUID? = nil) {
        var tasks: [Task<Void, Never>] = []
        var waiters: [CheckedContinuation<Bool, Never>] = []
        lock.withLock {
            if ticket == nil { closed = true }
            let owned = slots.values.filter { ticket == nil || $0.ticket == ticket }
            for slot in owned {
                slot.retired = true
                if let task = slot.task { tasks.append(task) }
                if let ready = slot.ready { waiters.append(ready) }
                slot.task = nil
                slot.ready = nil
                slots.removeValue(forKey: slot.identifier)
            }
        }
        // Cancellation handlers retire native requests and the shared export
        // lease synchronously, before a separate actor Cancel event is queued.
        tasks.forEach { $0.cancel() }
        waiters.forEach { $0.resume(returning: false) }
    }
}
