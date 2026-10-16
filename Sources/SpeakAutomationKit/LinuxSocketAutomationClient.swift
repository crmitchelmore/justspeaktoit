#if os(Linux)
import CLinuxAutomation
import Foundation
import SpeakCore

/// Linux uses a private per-user directory; it never modifies the permissions
/// of XDG_RUNTIME_DIR, /tmp or another shared ancestor.
public enum LinuxAutomationEndpoint {
    public static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userID: UInt32 = jsti_automation_uid()
    ) -> String {
        if let override = environment[AutomationEndpoint.environmentKey], !override.isEmpty { return override }
        let root = environment["XDG_RUNTIME_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        return "\(root)/\(ReleaseTrain.current.supportDirectory)-automation-\(userID)/automation.sock"
    }
}

/// One absolute monotonic deadline covers connect, all fragmented writes and
/// all fragmented reads. The native adapter suppresses SIGPIPE per send.
public struct UnixSocketAutomationClient: AutomationRequesting {
    public let socketPath: String

    public init(socketPath: String = LinuxAutomationEndpoint.socketPath()) { self.socketPath = socketPath }

    public func send(_ request: AutomationRequest) throws -> AutomationResponse {
        guard !socketPath.utf8.contains(0) else {
            throw AutomationError(code: .invalidArgument, message: "Automation socket paths cannot contain NUL.")
        }
        let frame = try AutomationWireExchange.requestFrame(for: request)
        let deadline = jsti_automation_deadline(
            UInt32((request.resolvedTimeout + AutomationClientTiming.responseGracePeriod) * 1_000)
        )
        var connection: OpaquePointer?
        try LinuxAutomationStream.check(jsti_automation_connect(socketPath, deadline, &connection))
        guard let connection else {
            throw AutomationError(code: .internalError, message: "The automation connection was not created.")
        }
        defer { jsti_automation_close(connection) }
        let stream = LinuxAutomationStream(connection: connection, deadline: deadline)
        try stream.writeAll(frame)
        return try AutomationWireExchange.readResponse(from: stream)
    }
}

public struct LinuxAutomationStream: AutomationByteStream {
    public let connection: OpaquePointer
    public let deadline: UInt64

    public init(connection: OpaquePointer, deadline: UInt64) {
        self.connection = connection
        self.deadline = deadline
    }

    public func readExactly(_ count: Int) throws -> Data {
        guard count >= 0, count <= AutomationLimits.maxFrameBytes else {
            throw AutomationError(code: .invalidArgument, message: "Automation read size is out of bounds.")
        }
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes {
            jsti_automation_read(connection, $0.baseAddress, count, deadline)
        }
        try Self.check(result)
        return data
    }

    public func writeAll(_ data: Data) throws {
        let result = data.withUnsafeBytes {
            jsti_automation_write(connection, $0.baseAddress, data.count, deadline)
        }
        try Self.check(result)
    }

    public static func check(_ status: Int32) throws {
        // Anonymous C enum constants import as `Int`; widen the Int32 status to match for pattern matching.
        switch Int(status) {
        case JSTI_AUTOMATION_OK: return
        case JSTI_AUTOMATION_TIMEOUT:
            throw AutomationError(code: .timedOut, message: "The local automation exchange timed out.")
        case JSTI_AUTOMATION_CANCELLED, JSTI_AUTOMATION_UNAVAILABLE:
            throw AutomationError(
                code: .appUnavailable,
                message: "Automation is unavailable. Start the app and enable Automation in General settings."
            )
        case JSTI_AUTOMATION_UNSAFE:
            throw AutomationError(
                code: .internalError,
                message: "Automation refused an unsafe endpoint, directory or peer. "
                    + "Use a user-owned 0700 directory and a user-owned 0600 socket, without symlink components."
            )
        default:
            throw AutomationError(code: .internalError, message: "The local automation socket operation failed.")
        }
    }
}
#endif
