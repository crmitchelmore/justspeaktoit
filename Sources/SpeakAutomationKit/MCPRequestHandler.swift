import Foundation
import SpeakCore

/// Pure JSON-RPC handler for the bundled MCP server.
///
/// Kept string-in/string-out so the whole MCP surface (initialize, tools/list,
/// tools/call, malformed input, app-not-running) is testable without spawning a
/// process or touching stdio.
public struct MCPRequestHandler {
    /// MCP revision this server implements. Echoed back during `initialize`;
    /// clients that ask for a different revision still get ours, per spec, and
    /// decide whether to continue.
    public static let protocolVersion = "2025-06-18"
    public static let serverName = "justspeaktoit"

    private let client: AutomationRequesting
    private let version: String

    public init(client: AutomationRequesting, version: String) {
        self.client = client
        self.version = version
    }

    /// Handles one newline-delimited JSON-RPC message.
    ///
    /// Returns nil for notifications, which must not produce a reply.
    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf8.count <= AutomationLimits.maxFrameBytes else {
            return Self.encode(Self.errorResponse(id: nil, code: -32600, message: "Request exceeds the size limit."))
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any] else {
            return Self.encode(Self.errorResponse(id: nil, code: -32700, message: "Parse error: invalid JSON."))
        }
        guard let method = message["method"] as? String else {
            return Self.encode(Self.errorResponse(
                id: message["id"],
                code: -32600,
                message: "Invalid request: missing \"method\"."
            ))
        }
        let identifier = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        // A message without an id is a notification: acknowledge by staying silent.
        guard identifier != nil else { return nil }

        switch method {
        case "initialize":
            return Self.encode(self.initializeResponse(id: identifier))
        case "ping":
            return Self.encode(Self.result(id: identifier, value: [:]))
        case "tools/list":
            return Self.encode(Self.result(id: identifier, value: ["tools": Self.toolDefinitions]))
        case "tools/call":
            return Self.encode(self.callTool(id: identifier, params: params))
        default:
            return Self.encode(Self.errorResponse(
                id: identifier,
                code: -32601,
                message: "Method not found: \(method)."
            ))
        }
    }

    // MARK: - Handlers

    private func initializeResponse(id: Any?) -> [String: Any] {
        Self.result(id: id, value: [
            "protocolVersion": Self.protocolVersion,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": Self.serverName, "version": self.version],
            "instructions": "Dictation and transcription tools backed by the running "
                + "Just Speak To It app. The app owns provider credentials; this server never sees them."
        ])
    }

    private func callTool(id: Any?, params: [String: Any]) -> [String: Any] {
        guard let name = params["name"] as? String else {
            return Self.errorResponse(id: id, code: -32602, message: "tools/call requires a \"name\".")
        }
        // The accepted surface must equal the advertised one: `AutomationCommand`
        // carries verbs the socket understands but this server never lists
        // (`status`), and answering those would make `tools/list` a lie.
        guard let command = AutomationCommand(rawValue: name), Self.advertisedToolNames.contains(name) else {
            return Self.errorResponse(id: id, code: -32602, message: "Unknown tool: \(name).")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        do {
            let request = try self.request(for: command, arguments: arguments, callID: id)
            let response = try self.client.send(request)
            if response.ok, let result = response.result {
                return Self.result(id: id, value: Self.toolResult(for: result, command: command, isError: false))
            }
            let error = response.error
                ?? AutomationError(code: .internalError, message: "The app reported a failure without a reason.")
            return Self.result(id: id, value: Self.toolFailure(error))
        } catch let error as AutomationError {
            // Tool-level failures are results, not protocol errors: the agent
            // should see them as content it can reason about and retry.
            return Self.result(id: id, value: Self.toolFailure(error))
        } catch {
            return Self.result(id: id, value: Self.toolFailure(
                AutomationError(code: .internalError, message: "Automation call failed.")
            ))
        }
    }

    private func request(for command: AutomationCommand, arguments: [String: Any], callID: Any?) throws
        -> AutomationRequest {
        var request = AutomationRequest(id: Self.requestID(for: callID), command: command)
        if let path = arguments["path"] {
            guard let path = path as? String else {
                throw AutomationError(code: .invalidArgument, message: "\"path\" must be a string.")
            }
            request.path = CommandLineParser.absolutePath(for: path)
        }
        if let limit = arguments["limit"] {
            guard let limit = limit as? Int else {
                throw AutomationError(code: .invalidArgument, message: "\"limit\" must be an integer.")
            }
            request.limit = limit
        }
        if let timeout = arguments["timeout_seconds"] {
            guard let timeout = timeout as? Double, timeout > 0 else {
                throw AutomationError(
                    code: .invalidArgument,
                    message: "\"timeout_seconds\" must be a positive number."
                )
            }
            request.timeout = timeout
        }
        return try request.validated()
    }

    /// Distinguishes this MCP server process from every other client of the
    /// socket. JSON-RPC call ids restart at `1` for each agent session, so
    /// without a per-process scope two unrelated sessions would collide on the
    /// app's idempotency cache.
    private static let processScope = String(UUID().uuidString.prefix(8))

    /// Derives the idempotency key from the JSON-RPC call id, so an agent that
    /// retries a timed-out `start_dictation` cannot open a second session.
    static func requestID(for callID: Any?) -> String {
        let raw: String
        switch callID {
        case let text as String: raw = text
        case let number as Int: raw = String(number)
        case let number as Double: raw = String(number)
        default: raw = UUID().uuidString
        }
        let scoped = "mcp-" + Self.processScope + "-" + raw
        return String(scoped.prefix(AutomationLimits.maxIdentifierLength))
    }

    // MARK: - Payloads

    static func toolResult(for result: AutomationResult, command: AutomationCommand, isError: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "content": [["type": "text", "text": CLIRunner.humanText(for: result, command: command)
                .trimmingCharacters(in: .whitespacesAndNewlines)]],
            "isError": isError
        ]
        if let structured = Self.structuredContent(for: result) {
            payload["structuredContent"] = structured
        }
        return payload
    }

    static func toolFailure(_ error: AutomationError) -> [String: Any] {
        [
            "content": [["type": "text", "text": "\(error.code.rawValue): \(error.message)"]],
            "isError": true
        ]
    }

    private static func structuredContent(for result: AutomationResult) -> [String: Any]? {
        guard let data = try? AutomationCoding.encoder().encode(result),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// Names from `toolDefinitions`, derived rather than restated so the two
    /// cannot drift.
    static let advertisedToolNames: Set<String> = Set(
        Self.toolDefinitions.compactMap { $0["name"] as? String }
    )

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": AutomationCommand.transcribeFile.rawValue,
            "description": "Transcribe a local audio file using the user's configured provider.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path to an audio file."],
                    "timeout_seconds": ["type": "number", "description": "Deadline in seconds."]
                ],
                "required": ["path"]
            ]
        ],
        [
            "name": AutomationCommand.getHistoryToolName,
            "description": "Return the most recent transcriptions, newest first.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": AutomationLimits.maxHistoryLimit,
                        "description": "How many entries to return (default \(AutomationLimits.defaultHistoryLimit))."
                    ]
                ]
            ]
        ],
        [
            "name": AutomationCommand.startDictation.rawValue,
            "description": "Start a dictation session in the app. Idempotent per call id.",
            "inputSchema": ["type": "object", "properties": [:]]
        ],
        [
            "name": AutomationCommand.stopDictation.rawValue,
            "description": "Stop the active dictation session and return its transcript.",
            "inputSchema": ["type": "object", "properties": [:]]
        ]
    ]

    // MARK: - JSON-RPC scaffolding

    static func result(id: Any?, value: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value]
    }

    static func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"error":{"code":-32603,"message":"Encoding failure"},"id":null,"jsonrpc":"2.0"}"#
        }
        return text
    }
}

extension AutomationCommand {
    /// The history command is named `get_history` on the wire and as an MCP tool;
    /// this alias keeps the tool table readable next to the other raw values.
    static var getHistoryToolName: String {
        AutomationCommand.history.rawValue
    }
}
