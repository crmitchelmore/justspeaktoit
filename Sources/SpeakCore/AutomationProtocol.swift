import Foundation

// MARK: - Automation Protocol

/// Schema identity for automation (CLI / MCP) requests and responses.
public enum AutomationSchema {
    /// Bumped only for breaking payload changes. Clients send the version they
    /// were built against and the app rejects anything it cannot speak, so a
    /// stale `speak` binary fails loudly instead of silently misreading a newer
    /// payload.
    public static let currentVersion = 1
}

/// Bounds applied to every automation payload on both sides of the socket.
///
/// The CLI is an untrusted local client (anything on the machine can connect to
/// the socket), so limits are enforced by the app as well as the client rather
/// than trusted from the wire.
public enum AutomationLimits {
    /// Largest accepted framed message. Requests and responses are metadata plus
    /// transcript text, never audio, so this is generous by design.
    public static let maxFrameBytes = 4 * 1024 * 1024
    public static let maxPathLength = 4096
    /// Audio is read by the app from disk, not streamed over the socket; this
    /// only stops obviously bogus inputs from tying up a transcription slot.
    public static let maxAudioFileBytes = 512 * 1024 * 1024
    public static let maxHistoryLimit = 200
    public static let defaultHistoryLimit = 10
    public static let maxIdentifierLength = 128
    /// Default client and server deadline for interactive commands.
    public static let defaultTimeout: TimeInterval = 15
    /// Deadline for file transcription, which is bounded by provider latency.
    public static let transcriptionTimeout: TimeInterval = 600
    public static let maxTimeout: TimeInterval = 3600
}

/// The automation verbs exposed over the local socket.
///
/// Raw values are the wire contract and are also reused as MCP tool names, so
/// the CLI, the app and the MCP server can never drift apart.
public enum AutomationCommand: String, Codable, Sendable, CaseIterable {
    case status
    case transcribeFile = "transcribe_file"
    case startDictation = "start_dictation"
    case stopDictation = "stop_dictation"
    case history = "get_history"
}

/// Stable machine-readable failure codes.
///
/// Callers (scripts, agents) branch on `code`; `message` is for humans and must
/// never carry API keys, tokens or full request payloads.
public enum AutomationErrorCode: String, Codable, Sendable {
    case appUnavailable = "app_unavailable"
    case schemaMismatch = "schema_mismatch"
    case invalidArgument = "invalid_argument"
    case unsupportedCommand = "unsupported_command"
    case fileNotFound = "file_not_found"
    case fileTooLarge = "file_too_large"
    case notRecording = "not_recording"
    case alreadyRecording = "already_recording"
    case transcriptionFailed = "transcription_failed"
    case timedOut = "timed_out"
    case internalError = "internal_error"
}

public struct AutomationError: Codable, Sendable, Equatable, LocalizedError {
    public let code: AutomationErrorCode
    public let message: String

    public init(code: AutomationErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        self.message
    }

    /// The socket is absent both when the app is closed and when automation
    /// is switched off in Settings; a client cannot tell the two apart, so the
    /// message names both causes and the switch that fixes the second.
    public static func appUnavailable(socketPath: String) -> AutomationError {
        AutomationError(
            code: .appUnavailable,
            message: "Just Speak To It isn't running, or automation is turned off "
                + "(no automation socket at \(socketPath)). Launch the app, turn on "
                + "Settings → General → Automation, and try again."
        )
    }
}

// MARK: - Request

public struct AutomationRequest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    /// Idempotency key. The app caches the response for a recently seen id and
    /// replays it instead of running the command twice, so a client that retries
    /// after a timeout cannot start two dictation sessions.
    public var id: String
    public var command: AutomationCommand
    public var path: String?
    public var profile: String?
    public var provider: String?
    public var limit: Int?
    public var timeout: TimeInterval?

    public init(
        schemaVersion: Int = AutomationSchema.currentVersion,
        id: String = UUID().uuidString,
        command: AutomationCommand,
        path: String? = nil,
        profile: String? = nil,
        provider: String? = nil,
        limit: Int? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.command = command
        self.path = path
        self.profile = profile
        self.provider = provider
        self.limit = limit
        self.timeout = timeout
    }

    /// The deadline to apply to this request, clamped to something a caller
    /// cannot use to pin a transcription slot open indefinitely.
    public var resolvedTimeout: TimeInterval {
        let fallback = self.command == .transcribeFile
            ? AutomationLimits.transcriptionTimeout
            : AutomationLimits.defaultTimeout
        guard let timeout, timeout > 0 else { return fallback }
        return min(timeout, AutomationLimits.maxTimeout)
    }

    /// Validates the request against the shared bounds.
    ///
    /// Runs on both ends: the CLI fails fast without a round trip, and the app
    /// re-checks because any local process can write to the socket.
    public func validated() throws -> AutomationRequest {
        guard self.schemaVersion == AutomationSchema.currentVersion else {
            throw AutomationError(
                code: .schemaMismatch,
                message: "Automation schema v\(self.schemaVersion) is not supported "
                    + "(this build speaks v\(AutomationSchema.currentVersion)). Update the app or the speak CLI."
            )
        }
        guard !self.id.isEmpty, self.id.count <= AutomationLimits.maxIdentifierLength else {
            throw AutomationError(
                code: .invalidArgument,
                message: "Request id must be 1-\(AutomationLimits.maxIdentifierLength) characters."
            )
        }
        try self.validateOptionalIdentifier(self.profile, label: "profile")
        try self.validateOptionalIdentifier(self.provider, label: "provider")

        switch self.command {
        case .transcribeFile:
            guard let path, !path.isEmpty else {
                throw AutomationError(code: .invalidArgument, message: "transcribe_file requires a file path.")
            }
            guard path.count <= AutomationLimits.maxPathLength else {
                throw AutomationError(
                    code: .invalidArgument,
                    message: "File path exceeds \(AutomationLimits.maxPathLength) characters."
                )
            }
        case .history:
            if let limit, limit < 1 || limit > AutomationLimits.maxHistoryLimit {
                throw AutomationError(
                    code: .invalidArgument,
                    message: "get_history limit must be between 1 and \(AutomationLimits.maxHistoryLimit)."
                )
            }
        case .status, .startDictation, .stopDictation:
            break
        }
        return self
    }

    /// History page size after defaulting and clamping.
    public var resolvedLimit: Int {
        guard let limit else { return AutomationLimits.defaultHistoryLimit }
        return min(max(limit, 1), AutomationLimits.maxHistoryLimit)
    }

    private func validateOptionalIdentifier(_ value: String?, label: String) throws {
        guard let value else { return }
        guard !value.isEmpty, value.count <= AutomationLimits.maxIdentifierLength else {
            throw AutomationError(
                code: .invalidArgument,
                message: "\(label) must be 1-\(AutomationLimits.maxIdentifierLength) characters."
            )
        }
    }
}

// MARK: - Response

public struct AutomationHistoryEntry: Codable, Sendable, Equatable {
    public let id: String
    public let text: String
    public let createdAt: Date
    public let model: String?
    public let durationSeconds: TimeInterval?
    public let wordCount: Int

    public init(
        id: String,
        text: String,
        createdAt: Date,
        model: String?,
        durationSeconds: TimeInterval?,
        wordCount: Int
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.model = model
        self.durationSeconds = durationSeconds
        self.wordCount = wordCount
    }
}

/// Union of every automation result field.
///
/// One struct with optional members (rather than a per-command enum) keeps the
/// JSON additive: a new field is invisible to older clients instead of breaking
/// their decode.
public struct AutomationResult: Codable, Sendable, Equatable {
    public var text: String?
    public var model: String?
    public var durationSeconds: TimeInterval?
    public var sessionActive: Bool?
    public var appVersion: String?
    public var entries: [AutomationHistoryEntry]?

    public init(
        text: String? = nil,
        model: String? = nil,
        durationSeconds: TimeInterval? = nil,
        sessionActive: Bool? = nil,
        appVersion: String? = nil,
        entries: [AutomationHistoryEntry]? = nil
    ) {
        self.text = text
        self.model = model
        self.durationSeconds = durationSeconds
        self.sessionActive = sessionActive
        self.appVersion = appVersion
        self.entries = entries
    }
}

public struct AutomationResponse: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var id: String
    public var command: AutomationCommand
    public var ok: Bool
    public var result: AutomationResult?
    public var error: AutomationError?

    public init(
        schemaVersion: Int = AutomationSchema.currentVersion,
        id: String,
        command: AutomationCommand,
        ok: Bool,
        result: AutomationResult? = nil,
        error: AutomationError? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.command = command
        self.ok = ok
        self.result = result
        self.error = error
    }

    public static func success(
        id: String,
        command: AutomationCommand,
        result: AutomationResult
    ) -> AutomationResponse {
        AutomationResponse(id: id, command: command, ok: true, result: result)
    }

    public static func failure(
        id: String,
        command: AutomationCommand,
        error: AutomationError
    ) -> AutomationResponse {
        AutomationResponse(id: id, command: command, ok: false, error: error)
    }
}

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
            .appendingPathComponent("SpeakApp", isDirectory: true)
            .appendingPathComponent("Automation", isDirectory: true)
            .appendingPathComponent("automation.sock")
            .path
    }
}
