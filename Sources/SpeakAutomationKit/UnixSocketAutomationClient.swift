import Foundation
import SpeakCore

/// Sends one automation request to the running app and waits for its reply.
///
/// A protocol so the CLI runner and the MCP server can be exercised end to end
/// against a stub, without a live app or a real socket.
public protocol AutomationRequesting {
    func send(_ request: AutomationRequest) throws -> AutomationResponse
}

/// How long transport IO outlives the app-side command deadline, so the app can
/// still encode and write its structured timeout reply. Shared by every client.
enum AutomationClientTiming {
    static let responseGracePeriod: TimeInterval = 1
}

#if canImport(Darwin)
/// Blocking UNIX-domain-socket client.
///
/// Each send blocks its worker, while an owned cancellation token can shut down
/// only that connection. MCP await workers never block the framing reader.
public struct UnixSocketAutomationClient: CancellableAutomationRequesting {
    /// Socket IO must outlive the app-side command deadline long enough for the
    /// server to encode and write its structured timeout response.
    static let responseGracePeriod: TimeInterval = AutomationClientTiming.responseGracePeriod

    public let socketPath: String
    private let onConnectWait: (@Sendable () -> Void)?
    private let connectAttempt: (@Sendable (Int32) -> Int32)?

    public init(socketPath: String = AutomationEndpoint.socketPath()) {
        self.socketPath = socketPath
        self.onConnectWait = nil
        self.connectAttempt = nil
    }

    init(socketPath: String, onConnectWait: @escaping @Sendable () -> Void) {
        self.socketPath = socketPath
        self.onConnectWait = onConnectWait
        self.connectAttempt = nil
    }

    /// Injects a connect errno against the real owned socket for deterministic retry-boundary tests.
    /// Zero means connected; production initializers always use Darwin.connect directly.
    init(socketPath: String, onConnectWait: @escaping @Sendable () -> Void,
         connectAttempt: @escaping @Sendable (Int32) -> Int32) {
        self.socketPath = socketPath
        self.onConnectWait = onConnectWait
        self.connectAttempt = connectAttempt
    }

    public func send(_ request: AutomationRequest) throws -> AutomationResponse {
        try self.send(request, cancellation: AutomationRequestCancellation())
    }

    public func send(
        _ request: AutomationRequest, cancellation: AutomationRequestCancellation
    ) throws -> AutomationResponse {
        guard !cancellation.isCancelled else {
            throw AutomationError(code: .appUnavailable, message: "Automation request cancelled.")
        }
        // Validated and framed before connecting, so a bad argument fails without
        // a round trip; framing and decoding are shared with every transport.
        let frame = try AutomationWireExchange.requestFrame(for: request)

        let descriptor = try self.connect(timeout: request.resolvedTimeout + Self.responseGracePeriod,
            cancellation: cancellation)
        defer {
            cancellation.uninstall()
            close(descriptor)
        }

        let stream = ConnectedSocket(client: self, descriptor: descriptor)
        try stream.writeAll(frame)
        let response = try AutomationWireExchange.readResponse(from: stream)
        if request.command == .awaitTranscript,
           response.id != request.id || response.command != .awaitTranscript {
            throw AutomationError(code: .unsupportedCommand,
                                  message: "The app does not support named capture await. Update the app and CLI.")
        }
        return response
    }

    /// The connected socket as the shared exchange reads it, keeping this
    /// client's errno-to-`AutomationError` mapping.
    private struct ConnectedSocket: AutomationByteStream {
        let client: UnixSocketAutomationClient
        let descriptor: Int32

        func readExactly(_ count: Int) throws -> Data {
            try self.client.readExactly(descriptor: self.descriptor, count: count)
        }

        func writeAll(_ data: Data) throws {
            try self.client.writeAll(descriptor: self.descriptor, data: data)
        }
    }

    // MARK: - Socket plumbing

    private func connect(timeout: TimeInterval, cancellation: AutomationRequestCancellation) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(self.socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            throw AutomationError(
                code: .invalidArgument,
                message: "Automation socket path is longer than the \(capacity - 1) byte platform limit."
            )
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for offset in 0..<pathBytes.count {
                    destination[offset] = CChar(bitPattern: pathBytes[offset])
                }
                destination[pathBytes.count] = 0
            }
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw AutomationError(code: .internalError, message: "Could not open a local socket.")
        }

        var connected = false
        cancellation.install { _ = shutdown(descriptor, SHUT_RDWR) }
        defer {
            if !connected {
                cancellation.uninstall()
                close(descriptor)
            }
        }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw AutomationError(code: .internalError, message: "Could not configure the local socket.")
        }
        self.applyTimeout(timeout, to: descriptor)
        // Without SO_NOSIGPIPE a write to an app that has just quit kills `speak`
        // with SIGPIPE instead of reporting that the app is unavailable.
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        try self.waitForConnection(descriptor, address: &address, size: size,
                                   timeout: timeout, cancellation: cancellation)
        guard !cancellation.isCancelled else {
            throw AutomationError(code: .appUnavailable, message: "Automation request cancelled.")
        }
        guard fcntl(descriptor, F_SETFL, flags) == 0 else {
            throw AutomationError(code: .internalError, message: "Could not configure the connected socket.")
        }
        connected = true
        return descriptor
    }

    private func waitForConnection(_ descriptor: Int32, address: inout sockaddr_un, size: socklen_t,
                                   timeout: TimeInterval, cancellation: AutomationRequestCancellation) throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(timeout))
        var reportedWait = false
        while true {
            guard !cancellation.isCancelled else {
                throw AutomationError(code: .appUnavailable, message: "Automation request cancelled.")
            }
            let failure = self.connectionFailure(descriptor, address: &address, size: size)
            if failure == 0 || failure == EISCONN { break }
            guard [EINPROGRESS, EALREADY, EINTR, EAGAIN].contains(failure) else {
                throw self.connectError(failure)
            }
            if !reportedWait { reportedWait = true; self.onConnectWait?() }
            guard ContinuousClock().now < deadline else {
                throw AutomationError(code: .timedOut, message: "Timed out connecting to the local automation socket.")
            }
            if failure == EAGAIN {
                // A full local listen backlog may not have an in-progress connect to poll.
                // Bound this retry pause; cancellation never waits for the 600-second request timeout.
                _ = poll(nil, 0, 25)
                continue
            }
            var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pending, 1, 25)
            if ready > 0 {
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
                    throw AutomationError(code: .internalError, message: "Local socket connection failed.")
                }
                if socketError == 0 { break }
                throw self.connectError(socketError)
            }
        }
    }

    private func connectionFailure(_ descriptor: Int32, address: inout sockaddr_un, size: socklen_t) -> Int32 {
        if let connectAttempt = self.connectAttempt { return connectAttempt(descriptor) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(descriptor, sockaddrPointer, size)
            }
        }
        return result == 0 ? 0 : errno
    }

    /// Only "nothing is listening" is reported as the app being unavailable;
    /// other connection failures name their real cause so a permission or
    /// path problem is not misdiagnosed as the app being closed.
    private func connectError(_ code: Int32) -> AutomationError {
        switch code {
        case ENOENT, ECONNREFUSED:
            // No socket file, or a stale one left by a crash: to the caller
            // both mean the app (or its automation service) is not there.
            return AutomationError.appUnavailable(socketPath: self.socketPath)
        case EACCES, EPERM:
            return AutomationError(
                code: .internalError,
                message: "The automation socket at \(self.socketPath) is not accessible to this user "
                    + "(\(String(cString: strerror(code))))."
            )
        default:
            return AutomationError(
                code: .internalError,
                message: "Could not connect to the automation socket at \(self.socketPath) "
                    + "(\(String(cString: strerror(code))))."
            )
        }
    }

    private func applyTimeout(_ timeout: TimeInterval, to descriptor: Int32) {
        let seconds = Int(timeout)
        var value = timeval(
            tv_sec: seconds,
            tv_usec: Int32((timeout - TimeInterval(seconds)) * 1_000_000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, size)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, size)
    }

    private func writeAll(descriptor: Int32, data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while sent < data.count {
                let written = Darwin.write(descriptor, base.advanced(by: sent), data.count - sent)
                if written > 0 {
                    sent += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                throw self.ioError(context: "sending the request")
            }
        }
    }

    private func readExactly(descriptor: Int32, count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let read = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return Darwin.read(descriptor, base.advanced(by: received), count - received)
            }
            if read > 0 {
                received += read
                continue
            }
            if read < 0, errno == EINTR { continue }
            if read == 0 {
                throw AutomationError(
                    code: .appUnavailable,
                    message: "Just Speak To It closed the automation connection before replying."
                )
            }
            throw self.ioError(context: "reading the reply")
        }
        return Data(buffer)
    }

    private func ioError(context: String) -> AutomationError {
        if errno == EAGAIN || errno == EWOULDBLOCK {
            return AutomationError(
                code: .timedOut,
                message: "Timed out \(context). Use --timeout to allow longer, or check the app is responsive."
            )
        }
        if errno == EPIPE || errno == ECONNRESET {
            // The app closed the socket mid-exchange, which is the same situation
            // for the caller as the app not running at all.
            return AutomationError.appUnavailable(socketPath: self.socketPath)
        }
        return AutomationError(code: .internalError, message: "Automation socket failed while \(context).")
    }
}
#endif
