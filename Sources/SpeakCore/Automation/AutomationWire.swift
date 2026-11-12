import Foundation

// MARK: - Coding

/// The single JSON coder pair used on the automation socket.
///
/// Dates are ISO-8601 on the wire so shell consumers (`jq`, agents) get a stable
/// string rather than a floating-point reference date.
public enum AutomationCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Framing

/// Length-prefixed framing shared by the automation client and server.
///
/// Mirrors the 4-byte big-endian prefix the iOS transport already uses, so both
/// local surfaces read the same way on the wire.
public enum AutomationFraming {
    public static let prefixLength = 4

    public static func frame(_ payload: Data) throws -> Data {
        guard payload.count <= AutomationLimits.maxFrameBytes else {
            throw AutomationError(
                code: .invalidArgument,
                message: "Automation message of \(payload.count) bytes exceeds the "
                    + "\(AutomationLimits.maxFrameBytes) byte limit."
            )
        }
        var length = UInt32(payload.count).bigEndian
        var framed = withUnsafeBytes(of: &length) { Data($0) }
        framed.append(payload)
        return framed
    }

    /// Reads the payload length from a 4-byte prefix, rejecting anything above
    /// the frame limit before a single byte of body is allocated.
    public static func payloadLength(from prefix: Data) throws -> Int {
        guard prefix.count == self.prefixLength else {
            throw AutomationError(code: .invalidArgument, message: "Truncated automation length prefix.")
        }
        let length = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length > 0, Int(length) <= AutomationLimits.maxFrameBytes else {
            throw AutomationError(
                code: .invalidArgument,
                message: "Automation message length \(length) is out of bounds."
            )
        }
        return Int(length)
    }
}

// MARK: - Endpoint

/// Resolves the local socket both ends use.
public enum AutomationEndpoint {
    /// Overrides the socket path; used by tests and by anyone running a second
    /// app instance. Read by the app and the CLI alike so they cannot disagree.
    public static let environmentKey = "SPEAK_AUTOMATION_SOCKET"

    public static func socketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String {
        if let override = environment[self.environmentKey], !override.isEmpty {
            return override
        }
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return support
            .appendingPathComponent(ReleaseTrain.current.supportDirectory, isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
            .appendingPathComponent("automation.sock")
            .path
    }
}
