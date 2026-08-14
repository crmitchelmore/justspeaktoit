import Foundation
import SpeakCore

/// Sends one automation request to the running app and waits for its reply.
///
/// A protocol so the CLI runner and the MCP server can be exercised end to end
/// against a stub, without a live app or a real socket.
public protocol AutomationRequesting {
    func send(_ request: AutomationRequest) throws -> AutomationResponse
}

/// Blocking UNIX-domain-socket client.
///
/// Blocking is deliberate: `speak` is a one-shot process and the MCP server
/// handles a single JSON-RPC request at a time, so an event loop would add
/// concurrency risk for no benefit.
public struct UnixSocketAutomationClient: AutomationRequesting {
    /// Socket IO must outlive the app-side command deadline long enough for the
    /// server to encode and write its structured timeout response.
    static let responseGracePeriod: TimeInterval = 1

    public let socketPath: String

    public init(socketPath: String = AutomationEndpoint.socketPath()) {
        self.socketPath = socketPath
    }

    public func send(_ request: AutomationRequest) throws -> AutomationResponse {
        let validated = try request.validated()
        let payload = try AutomationCoding.encoder().encode(validated)
        let frame = try AutomationFraming.frame(payload)

        let descriptor = try self.connect(timeout: validated.resolvedTimeout + Self.responseGracePeriod)
        defer { close(descriptor) }

        try self.writeAll(descriptor: descriptor, data: frame)
        let prefix = try self.readExactly(descriptor: descriptor, count: AutomationFraming.prefixLength)
        let length = try AutomationFraming.payloadLength(from: prefix)
        let body = try self.readExactly(descriptor: descriptor, count: length)

        do {
            let response = try AutomationCoding.decoder().decode(AutomationResponse.self, from: body)
            guard response.schemaVersion == AutomationSchema.currentVersion else {
                throw AutomationError(
                    code: .schemaMismatch,
                    message: "The app replied with automation schema v\(response.schemaVersion); "
                        + "this speak build understands v\(AutomationSchema.currentVersion). Update the CLI."
                )
            }
            return response
        } catch let error as AutomationError {
            throw error
        } catch {
            // Never echo the raw body: it is app-controlled and could contain
            // transcript text the caller did not ask for.
            throw AutomationError(code: .internalError, message: "Could not decode the app's automation reply.")
        }
    }

    // MARK: - Socket plumbing

    private func connect(timeout: TimeInterval) throws -> Int32 {
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

        self.applyTimeout(timeout, to: descriptor)
        // Without SO_NOSIGPIPE a write to an app that has just quit kills `speak`
        // with SIGPIPE instead of reporting that the app is unavailable.
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(descriptor, sockaddrPointer, size)
            }
        }
        guard result == 0 else {
            close(descriptor)
            // ENOENT/ECONNREFUSED both mean "nothing is listening": a stale socket
            // file left by a crash looks identical to no file at all to the caller.
            throw AutomationError.appUnavailable(socketPath: self.socketPath)
        }
        return descriptor
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
