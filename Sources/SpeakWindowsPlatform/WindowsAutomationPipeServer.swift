import CWindowsAutomation
import Foundation
import SpeakCore

/// The app side of `speak` on Windows: a same-user named pipe answering one
/// length-prefixed request per connection through the shared
/// `AutomationRequestCoordinator`, exactly as the macOS socket server does.
///
/// It owns only bytes and lifetimes. One accept thread waits on the native
/// listener; each connection is served on its own thread, whose blocking pipe
/// I/O is bounded by the request's own deadline and never runs on the UI
/// thread or the Swift cooperative pool. The native layer admits only this
/// user, on this computer, at no lower integrity than the app.
public final class WindowsAutomationPipeServer: @unchecked Sendable {
    /// Most clients served at once; later clients wait for a free instance.
    public static let maxInstances: UInt32 = 4
    /// How long a client may take to send its request once connected.
    static let requestTimeout: UInt32 = 10_000
    /// Bounded wait for a client to read its reply before disconnecting.
    static let drainTimeout: UInt32 = 2_000

    public let pipeName: String
    private let coordinator: AutomationRequestCoordinator
    private let lock = NSLock()
    private var listener: OpaquePointer?
    private var acceptFinished: DispatchSemaphore?

    public init(pipeName: String, coordinator: AutomationRequestCoordinator = AutomationRequestCoordinator()) {
        self.pipeName = pipeName
        self.coordinator = coordinator
    }

    public var isRunning: Bool { lock.withLock { listener != nil } }

    /// Starts answering with `handler`. Throws when the pipe is already owned,
    /// for example by another running instance of the app.
    public func start(handler: @escaping AutomationRequestCoordinator.Handler) throws {
        try lock.withLock {
            guard listener == nil else { return }
            var created: OpaquePointer?
            var error = [CChar](repeating: 0, count: 512)
            let status = jsti_automation_pipe_listen(pipeName, Self.maxInstances, &created, &error, error.count)
            guard status == JSTI_AUTOMATION_PIPE_OK.rawValue, let created else {
                throw AutomationError(
                    code: .internalError,
                    message: status == JSTI_AUTOMATION_PIPE_IN_USE.rawValue
                        ? "Another Just Speak to It window already serves automation for this user."
                        : String(cString: error)
                )
            }
            coordinator.activate(handler)
            listener = created
            let finished = DispatchSemaphore(value: 0)
            acceptFinished = finished
            let handle = PipeHandle(pointer: created)
            let thread = Thread { [self] in
                self.acceptLoop(handle.pointer)
                finished.signal()
            }
            thread.name = "JustSpeakToIt automation accept"
            thread.start()
        }
    }

    /// Stops accepting, cancels running commands' replies and waits for the
    /// accept thread. Connections still being served end with the pipe closed.
    public func stop() {
        let (owned, finished) = lock.withLock { () -> (OpaquePointer?, DispatchSemaphore?) in
            defer { listener = nil; acceptFinished = nil }
            return (listener, acceptFinished)
        }
        guard let owned else { return }
        coordinator.deactivate()
        _ = jsti_automation_pipe_stop(owned, 3_000)
        finished?.wait()
        jsti_automation_pipe_listener_release(owned)
    }

    private func acceptLoop(_ listener: OpaquePointer) {
        while true {
            var connection: OpaquePointer?
            var error = [CChar](repeating: 0, count: 512)
            let status = jsti_automation_pipe_accept(listener, &connection, &error, error.count)
            if status == JSTI_AUTOMATION_PIPE_CANCELLED.rawValue { return }
            guard status == JSTI_AUTOMATION_PIPE_OK.rawValue, let connection else {
                // Back off without polling; a stop ends the wait at once.
                if jsti_automation_pipe_wait_for_stop(listener, 1_000) == 1 { return }
                continue
            }
            let handle = PipeHandle(pointer: connection)
            let serving = Thread { [self] in self.serve(handle.pointer) }
            serving.name = "JustSpeakToIt automation client"
            serving.start()
        }
    }

    private func serve(_ connection: OpaquePointer) {
        defer { jsti_automation_pipe_close(connection) }
        let request: AutomationRequest
        do {
            request = try AutomationWireExchange.readRequest(
                from: PipeStream(connection: connection, timeout: Self.requestTimeout)
            )
        } catch let failure as PipeFailure {
            // Untrusted, vanished or cancelled clients receive nothing.
            _ = failure
            return
        } catch {
            let response = AutomationWireExchange.malformedRequestResponse(for: error)
            reply(response, on: connection, timeout: Self.requestTimeout)
            return
        }
        let answered = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        let coordinator = coordinator
        Task.detached {
            box.value = await coordinator.respond(to: request)
            answered.signal()
        }
        answered.wait()
        guard let response = box.value else { return }
        let seconds = request.resolvedTimeout + 5
        reply(response, on: connection, timeout: UInt32(clamping: Int(seconds * 1_000)))
    }

    private func reply(_ response: AutomationResponse, on connection: OpaquePointer, timeout: UInt32) {
        guard let frame = AutomationWireExchange.responseFrame(for: response) else { return }
        do {
            try PipeStream(connection: connection, timeout: timeout).writeAll(frame)
            _ = jsti_automation_pipe_drain(connection, Self.drainTimeout)
        } catch {
            // The client left; there is nobody to tell.
        }
    }

    private final class ResponseBox: @unchecked Sendable {
        var value: AutomationResponse?
    }

    struct PipeFailure: Error {
        let status: Int32
    }

    struct PipeStream: AutomationByteStream {
        let connection: OpaquePointer
        let timeout: UInt32

        func readExactly(_ count: Int) throws -> Data {
            guard count > 0 else { return Data() }
            var bytes = [UInt8](repeating: 0, count: count)
            let status = jsti_automation_pipe_read(connection, &bytes, count, timeout, nil, 0)
            guard status == JSTI_AUTOMATION_PIPE_OK.rawValue else { throw PipeFailure(status: status) }
            return Data(bytes)
        }

        func writeAll(_ data: Data) throws {
            let status = data.withUnsafeBytes { buffer in
                jsti_automation_pipe_write(
                    connection, buffer.bindMemory(to: UInt8.self).baseAddress, data.count, timeout, nil, 0
                )
            }
            guard status == JSTI_AUTOMATION_PIPE_OK.rawValue else { throw PipeFailure(status: status) }
        }
    }

    /// The pipe name for this user and release train, honouring the
    /// `SPEAK_AUTOMATION_PIPE` override exactly as `speak` does.
    public static func defaultPipeName(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        var required = 0
        _ = jsti_automation_user_sid(nil, 0, &required, nil, 0)
        var sid = [CChar](repeating: 0, count: max(required, 1))
        guard required > 0, jsti_automation_user_sid(&sid, sid.count, &required, nil, 0) == 0 else {
            throw AutomationError(code: .internalError, message: "Could not identify the current Windows user.")
        }
        return try AutomationPipeEndpoint.pipeName(userSID: String(cString: sid), environment: environment)
    }
}

/// A native pipe handle handed to exactly one thread, which owns it from then on.
private struct PipeHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}
