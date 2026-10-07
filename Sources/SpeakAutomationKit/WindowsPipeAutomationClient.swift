#if os(Windows)
import CWindowsAutomation
import Foundation
import SpeakCore

/// Blocking named-pipe client for the Windows app, the counterpart of
/// `UnixSocketAutomationClient`.
///
/// The pipe name comes from `AutomationPipeEndpoint`, so the CLI and the app
/// derive it from one policy. The native layer opens only this computer's pipe
/// namespace and requires the pipe to be owned by this user before a request is
/// written, so a name squatted by another account never receives one.
public struct WindowsPipeAutomationClient: AutomationRequesting {
    public let pipeName: String?
    private let nameError: AutomationError?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        do {
            pipeName = try AutomationPipeEndpoint.pipeName(userSID: Self.userSID(), environment: environment)
            nameError = nil
        } catch let error as AutomationError {
            pipeName = nil
            nameError = error
        } catch {
            pipeName = nil
            nameError = AutomationError(code: .internalError, message: "Could not name the automation pipe.")
        }
    }

    public func send(_ request: AutomationRequest) throws -> AutomationResponse {
        let frame = try AutomationWireExchange.requestFrame(for: request)
        guard let pipeName else {
            throw nameError ?? AutomationError(code: .internalError, message: "Could not name the automation pipe.")
        }
        let seconds = request.resolvedTimeout + AutomationClientTiming.responseGracePeriod
        let timeout = UInt32(clamping: Int((seconds * 1_000).rounded(.up)))
        var connection: OpaquePointer?
        var error = [CChar](repeating: 0, count: 512)
        let status = jsti_automation_pipe_connect(pipeName, timeout, &connection, &error, error.count)
        guard status == JSTI_AUTOMATION_PIPE_OK.rawValue, let connection else {
            throw Self.error(status: status, detail: String(cString: error), pipeName: pipeName)
        }
        defer { jsti_automation_pipe_close(connection) }
        let stream = Stream(connection: connection, timeout: timeout, pipeName: pipeName)
        try stream.writeAll(frame)
        return try AutomationWireExchange.readResponse(from: stream)
    }

    /// The connected pipe as the shared exchange reads it.
    private struct Stream: AutomationByteStream {
        let connection: OpaquePointer
        let timeout: UInt32
        let pipeName: String

        func readExactly(_ count: Int) throws -> Data {
            guard count > 0 else { return Data() }
            var bytes = [UInt8](repeating: 0, count: count)
            var error = [CChar](repeating: 0, count: 512)
            let status = jsti_automation_pipe_read(connection, &bytes, count, timeout, &error, error.count)
            guard status == JSTI_AUTOMATION_PIPE_OK.rawValue else {
                throw WindowsPipeAutomationClient.error(
                    status: status, detail: String(cString: error), pipeName: pipeName, reading: true
                )
            }
            return Data(bytes)
        }

        func writeAll(_ data: Data) throws {
            var error = [CChar](repeating: 0, count: 512)
            let status = data.withUnsafeBytes { buffer in
                jsti_automation_pipe_write(
                    connection, buffer.bindMemory(to: UInt8.self).baseAddress, data.count, timeout, &error, error.count
                )
            }
            guard status == JSTI_AUTOMATION_PIPE_OK.rawValue else {
                throw WindowsPipeAutomationClient.error(
                    status: status, detail: String(cString: error), pipeName: pipeName
                )
            }
        }
    }

    /// Only "nothing is listening" and a peer that went away mid-exchange are
    /// reported as the app being unavailable; other failures name their cause.
    static func error(status: Int32, detail: String, pipeName: String, reading: Bool = false) -> AutomationError {
        switch status {
        case JSTI_AUTOMATION_PIPE_NOT_FOUND.rawValue:
            return AutomationError(
                code: .appUnavailable,
                message: "Just Speak To It isn't running, or automation is turned off, so its automation "
                    + "pipe \(pipeName) could not be reached. Launch the app, allow automation in its "
                    + "Settings menu, and try again."
            )
        case JSTI_AUTOMATION_PIPE_CLOSED.rawValue:
            return AutomationError(
                code: .appUnavailable,
                message: reading ? "Just Speak To It closed the automation connection before replying."
                    : "Just Speak To It closed the automation connection."
            )
        case JSTI_AUTOMATION_PIPE_TIMED_OUT.rawValue:
            return AutomationError(
                code: .timedOut,
                message: "Timed out waiting for Just Speak To It. Use --timeout to allow longer, "
                    + "or check the app is responsive."
            )
        case JSTI_AUTOMATION_PIPE_ACCESS_DENIED.rawValue, JSTI_AUTOMATION_PIPE_UNTRUSTED.rawValue:
            return AutomationError(
                code: .internalError,
                message: "The automation pipe \(pipeName) does not belong to this Windows user, so no request "
                    + "was sent."
            )
        default:
            return AutomationError(
                code: .internalError,
                message: detail.isEmpty ? "The automation pipe failed." : detail
            )
        }
    }

    static func userSID() throws -> String {
        var required = 0
        var error = [CChar](repeating: 0, count: 256)
        _ = jsti_automation_user_sid(nil, 0, &required, &error, error.count)
        guard required > 0, required <= 256 else {
            throw AutomationError(code: .internalError, message: "Could not identify the current Windows user.")
        }
        var sid = [CChar](repeating: 0, count: required)
        guard jsti_automation_user_sid(&sid, sid.count, &required, &error, error.count) == 0 else {
            throw AutomationError(code: .internalError, message: "Could not identify the current Windows user.")
        }
        return String(cString: sid)
    }
}

/// Writes CLI output so Unicode transcripts render in a console whatever its
/// code page, and passes bytes through unchanged when redirected.
public enum WindowsConsoleOutput {
    public static func write(_ text: String, toStandardError: Bool) {
        guard !text.isEmpty else { return }
        let bytes = Array(text.utf8)
        let written = bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                jsti_automation_console_write(toStandardError ? 2 : 1, $0, buffer.count)
            }
        }
        if written != 1 {
            (toStandardError ? FileHandle.standardError : FileHandle.standardOutput).write(Data(bytes))
        }
    }
}
#endif
