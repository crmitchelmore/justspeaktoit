import CWindowsAutomation
import Foundation
import SpeakCore
import SpeakDesktop

/// Single-instance link forwarding for the Windows app.
///
/// The first interactive window listens on `DesktopActivationEndpoint`'s pipe,
/// created with `FILE_FLAG_FIRST_PIPE_INSTANCE`, so owning the pipe is also the
/// single-instance check. When a browser launches the app for a
/// `justspeaktoit://` link (MSIX protocol activation passes the link as the
/// first argument), the new process finds the pipe in use, forwards the link
/// with `forward` and exits; the window that owns the pending sign-in or the
/// recorder performs it. The native layer admits only this user's processes,
/// on this computer, at no lower integrity than the app, exactly as for the
/// automation pipe, so a sandboxed browser renderer cannot write to it.
public final class WindowsActivationServer: @unchecked Sendable {
    /// Links are tiny; a client that has not sent one within this is dropped.
    static let readTimeout: UInt32 = 5_000
    static let replyTimeout: UInt32 = 5_000

    public typealias Handler = @Sendable (String) async -> DesktopActivationFrame.Reply

    public let pipeName: String
    private let lock = NSLock()
    private var listener: OpaquePointer?
    private var acceptFinished: DispatchSemaphore?

    public init(pipeName: String) {
        self.pipeName = pipeName
    }

    public enum StartOutcome: Equatable, Sendable {
        case listening
        /// Another process of this user already owns the pipe: another window.
        case anotherInstanceIsRunning
    }

    /// Starts serving forwarded links with `handler`, one connection at a time.
    public func start(handler: @escaping Handler) throws -> StartOutcome {
        try lock.withLock {
            guard listener == nil else { return .listening }
            var created: OpaquePointer?
            var error = [CChar](repeating: 0, count: 512)
            let status = jsti_automation_pipe_listen(pipeName, 1, &created, &error, error.count)
            if status == JSTI_AUTOMATION_PIPE_IN_USE.rawValue { return .anotherInstanceIsRunning }
            guard status == JSTI_AUTOMATION_PIPE_OK.rawValue, let created else {
                throw WindowsActivationError(message: "Could not listen for links: \(String(cString: error))")
            }
            listener = created
            let finished = DispatchSemaphore(value: 0)
            acceptFinished = finished
            let handle = ActivationPipeHandle(pointer: created)
            let thread = Thread {
                Self.acceptLoop(handle.pointer, handler: handler)
                finished.signal()
            }
            thread.name = "JustSpeakToIt activation accept"
            thread.start()
            return .listening
        }
    }

    public var isRunning: Bool { lock.withLock { listener != nil } }

    /// Stops listening and waits for the accept thread. Idempotent.
    public func stop() {
        let (owned, finished) = lock.withLock { () -> (OpaquePointer?, DispatchSemaphore?) in
            defer { listener = nil; acceptFinished = nil }
            return (listener, acceptFinished)
        }
        guard let owned else { return }
        _ = jsti_automation_pipe_stop(owned, 3_000)
        finished?.wait()
        jsti_automation_pipe_listener_release(owned)
    }

    private static func acceptLoop(_ listener: OpaquePointer, handler: @escaping Handler) {
        while true {
            var connection: OpaquePointer?
            let status = jsti_automation_pipe_accept(listener, &connection, nil, 0)
            if status == JSTI_AUTOMATION_PIPE_CANCELLED.rawValue { return }
            guard status == JSTI_AUTOMATION_PIPE_OK.rawValue, let connection else {
                if jsti_automation_pipe_wait_for_stop(listener, 1_000) == 1 { return }
                continue
            }
            // One link at a time, in arrival order: a forwarded sign-in and a
            // recorder command never overtake each other.
            serve(connection, handler: handler)
        }
    }

    private static func serve(_ connection: OpaquePointer, handler: @escaping Handler) {
        defer { jsti_automation_pipe_close(connection) }
        let reply: DesktopActivationFrame.Reply
        do {
            let header = try read(connection, count: DesktopActivationFrame.headerLength)
            guard let length = DesktopActivationFrame.bodyLength(ofHeader: header),
                  let link = DesktopActivationFrame.link(fromBody: try read(connection, count: length)) else {
                write(.malformed, to: connection)
                return
            }
            let box = ReplyBox()
            let answered = DispatchSemaphore(value: 0)
            Task.detached {
                box.value = await handler(link)
                answered.signal()
            }
            answered.wait()
            reply = box.value ?? .refused
        } catch {
            // An untrusted, vanished or stalled client receives nothing.
            return
        }
        write(reply, to: connection)
    }

    private static func read(_ connection: OpaquePointer, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = jsti_automation_pipe_read(connection, &bytes, count, readTimeout, nil, 0)
        guard status == JSTI_AUTOMATION_PIPE_OK.rawValue else { throw WindowsActivationError(status: status) }
        return Data(bytes)
    }

    private static func write(_ reply: DesktopActivationFrame.Reply, to connection: OpaquePointer) {
        var byte = reply.rawValue
        guard jsti_automation_pipe_write(connection, &byte, 1, replyTimeout, nil, 0)
                == JSTI_AUTOMATION_PIPE_OK.rawValue else { return }
        _ = jsti_automation_pipe_drain(connection, 2_000)
    }

    private final class ReplyBox: @unchecked Sendable {
        var value: DesktopActivationFrame.Reply?
    }

    /// Sends `link` to the window listening on `pipeName` and returns its
    /// answer. The client requires the pipe to be owned by this user, so a
    /// name squatted by another account never receives the link.
    public static func forward(
        _ link: String, pipeName: String, timeoutMilliseconds: UInt32 = 5_000
    ) throws -> DesktopActivationFrame.Reply {
        let frame = try DesktopActivationFrame.encode(link)
        var connection: OpaquePointer?
        var error = [CChar](repeating: 0, count: 512)
        let status = jsti_automation_pipe_connect(pipeName, timeoutMilliseconds, &connection, &error, error.count)
        guard status == JSTI_AUTOMATION_PIPE_OK.rawValue, let connection else {
            throw WindowsActivationError(status: status, detail: String(cString: error))
        }
        defer { jsti_automation_pipe_close(connection) }
        let written = frame.withUnsafeBytes { buffer in
            jsti_automation_pipe_write(
                connection, buffer.bindMemory(to: UInt8.self).baseAddress, frame.count, timeoutMilliseconds, nil, 0
            )
        }
        guard written == JSTI_AUTOMATION_PIPE_OK.rawValue else { throw WindowsActivationError(status: written) }
        // The window answers once it has handled the link, which may include
        // a hop to its controller; allow for that beyond the write timeout.
        var byte: UInt8 = 0
        let read = jsti_automation_pipe_read(connection, &byte, 1, timeoutMilliseconds * 2, nil, 0)
        guard read == JSTI_AUTOMATION_PIPE_OK.rawValue else { throw WindowsActivationError(status: read) }
        guard let reply = DesktopActivationFrame.Reply(rawValue: byte) else {
            throw WindowsActivationError(message: "The running window gave an unexpected answer.")
        }
        return reply
    }

    /// The activation pipe for this user and release train.
    public static func defaultPipeName(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        var required = 0
        _ = jsti_automation_user_sid(nil, 0, &required, nil, 0)
        var sid = [CChar](repeating: 0, count: max(required, 1))
        guard required > 0, jsti_automation_user_sid(&sid, sid.count, &required, nil, 0) == 0 else {
            throw WindowsActivationError(message: "Could not identify the current Windows user.")
        }
        return try DesktopActivationEndpoint.pipeName(userSID: String(cString: sid), environment: environment)
    }
}

public struct WindowsActivationError: Error, LocalizedError, Equatable {
    public let message: String
    public let status: Int32?

    public init(message: String) {
        self.message = message
        self.status = nil
    }

    init(status: Int32, detail: String = "") {
        self.status = status
        switch status {
        case JSTI_AUTOMATION_PIPE_NOT_FOUND.rawValue: message = "Just Speak to It is not running."
        case JSTI_AUTOMATION_PIPE_UNTRUSTED.rawValue:
            message = "The running window is not this user's; the link was not sent."
        case JSTI_AUTOMATION_PIPE_TIMED_OUT.rawValue: message = "The running window did not answer in time."
        default: message = detail.isEmpty ? "The link could not be forwarded (\(status))." : detail
        }
    }

    public var errorDescription: String? { message }
}

private struct ActivationPipeHandle: @unchecked Sendable {
    let pointer: OpaquePointer
}
