import CLinuxAutomation
import Foundation
import SpeakAutomationKit
import SpeakCore

/// Byte/lifetime adapter only. Commands, replay and in-flight joining remain
/// owned by the canonical coordinator. No GTK, devices or provider dependencies.
public final class LinuxAutomationServer: @unchecked Sendable {
    public static let maximumConnections = 4
    private let lifecycle = NSLock()
    private let lock = NSLock()
    private let workers = DispatchGroup()
    private let accepted = DispatchGroup()
    private let coordinator: AutomationRequestCoordinator
    private var listener: NativeHandle?
    private var failed = false
    private var replies: [UUID: Task<Void, Never>] = [:]
    public let socketPath: String
    private let requestMilliseconds: UInt32
    private let onFailure: @Sendable () -> Void

    public init(
        socketPath: String = LinuxAutomationEndpoint.socketPath(),
        requestMilliseconds: UInt32 = 10_000,
        coordinator: AutomationRequestCoordinator = .init(
            maxInFlightRequests: LinuxAutomationServer.maximumConnections
        ),
        onFailure: @escaping @Sendable () -> Void = {}
    ) {
        self.socketPath = socketPath
        self.requestMilliseconds = requestMilliseconds
        self.coordinator = coordinator
        self.onFailure = onFailure
    }

    public var isRunning: Bool {
        lock.withLock {
            guard let listener, !failed else { return false }
            return jsti_automation_listener_status(listener.pointer) == JSTI_AUTOMATION_OK
        }
    }

    /// Blocking lifecycle calls belong on a dedicated thread, never GTK or an actor.
    public func start(handler: @escaping AutomationRequestCoordinator.Handler) throws {
        try lifecycle.withLock {
            guard !socketPath.utf8.contains(0) else {
                throw AutomationError(code: .invalidArgument, message: "Automation socket paths cannot contain NUL.")
            }
            guard lock.withLock({ listener == nil }) else {
                if isRunning { return }
                throw AutomationError(
                    code: .internalError, message: "Stop the failed automation listener before retrying."
                )
            }
            var pointer: OpaquePointer?
            try LinuxAutomationStream.check(jsti_automation_listen(socketPath, &pointer))
            guard let pointer else {
                throw AutomationError(code: .internalError, message: "The automation listener was not created.")
            }
            let handle = NativeHandle(pointer: pointer)
            coordinator.activate(handler)
            lock.withLock { listener = handle; failed = false }
            accepted.enter()
            Thread { [self] in
                defer { accepted.leave() }
                accept(handle)
            }.start()
        }
    }

    public func stop() {
        lifecycle.withLock {
            let owned = lock.withLock { () -> NativeHandle? in
                defer { listener = nil }
                return listener
            }
            guard let owned else { return }
            coordinator.deactivate()
            jsti_automation_stop(owned.pointer)
            lock.withLock { replies.values.forEach { $0.cancel() } }
            accepted.wait()
            workers.wait()
            jsti_automation_release(owned.pointer)
        }
    }

    private func accept(_ handle: NativeHandle) {
        while true {
            var connection: OpaquePointer?
            let status = jsti_automation_accept(handle.pointer, &connection)
            if status == JSTI_AUTOMATION_CANCELLED { return }
            guard status == JSTI_AUTOMATION_OK, let connection else {
                // Fail closed, not a busy-looping or success-shaped listener.
                lock.withLock { failed = true; replies.values.forEach { $0.cancel() } }
                coordinator.deactivate()
                jsti_automation_stop(handle.pointer)
                FileHandle.standardError.write(Data("Automation listener failed and was stopped.\n".utf8))
                onFailure()
                return
            }
            let connectionHandle = NativeHandle(pointer: connection)
            workers.enter()
            Thread { [self] in
                defer { jsti_automation_close(connectionHandle.pointer); workers.leave() }
                serve(connectionHandle)
            }.start()
        }
    }

    private func serve(_ handle: NativeHandle) {
        let readDeadline = jsti_automation_deadline(requestMilliseconds)
        let stream = LinuxAutomationStream(connection: handle.pointer, deadline: readDeadline)
        let request: AutomationRequest
        do {
            request = try AutomationWireExchange.readRequest(from: stream)
        } catch let error as AutomationError where error.code != .invalidArgument && error.code != .schemaMismatch {
            return // Disconnected, cancelled or slow client: there is no reply recipient.
        } catch {
            reply(AutomationWireExchange.malformedRequestResponse(for: error), on: handle)
            return
        }
        let answered = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let identifier = UUID()
        let admitted = lock.withLock { () -> Bool in
            guard listener != nil, !failed else { return false }
            replies[identifier] = Task.detached { [coordinator] in
                box.set(await coordinator.respond(to: request))
                answered.signal()
            }
            return true
        }
        guard admitted else { return }
        answered.wait()
        lock.withLock { _ = replies.removeValue(forKey: identifier) }
        if let response = box.get() { reply(response, on: handle) }
    }

    private func reply(_ response: AutomationResponse, on handle: NativeHandle) {
        guard let frame = AutomationWireExchange.responseFrame(for: response) else { return }
        do {
            try LinuxAutomationStream(
                connection: handle.pointer, deadline: jsti_automation_deadline(2_000)
            ).writeAll(frame)
        } catch {
            // Transport failure means the client left or disable interrupted IO.
        }
    }
}

private struct NativeHandle: @unchecked Sendable { let pointer: OpaquePointer }
private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AutomationResponse?
    func set(_ response: AutomationResponse) { lock.withLock { value = response } }
    func get() -> AutomationResponse? { lock.withLock { value } }
}
