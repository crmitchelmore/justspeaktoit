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
        self.handle(line: line, cancellation: nil)
    }

    func handle(line: String, cancellation: AutomationRequestCancellation?) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf8.count <= AutomationLimits.maxFrameBytes else {
            return Self.encode(Self.errorResponse(id: nil, code: -32600, message: "Request exceeds the size limit."))
        }
        let data = Data(trimmed.utf8)
        guard let message = JSONRPCRequest.decode(data) else {
            return Self.encode(Self.errorResponse(id: nil, code: -32700, message: "Parse error: invalid JSON."))
        }
        // Rebuilt rather than echoed as parsed, so a numeric id is written back as
        // the same number on every platform (see `MCPJSONValue`).
        let identifier = message.id?.jsonRPCID
        guard let method = message.methodName else {
            return Self.encode(Self.errorResponse(
                id: identifier,
                code: -32600,
                message: "Invalid request: missing \"method\"."
            ))
        }

        // A message without an id is a notification: acknowledge by staying silent.
        guard let identifier else { return nil }

        switch method {
        case "initialize":
            return Self.encode(JSONRPCResponse(id: identifier, result: self.initializeResult))
        case "ping":
            return Self.encode(JSONRPCResponse(id: identifier, result: MCPEmptyResult()))
        case "tools/list":
            return Self.encode(JSONRPCResponse(id: identifier, result: MCPToolList(tools: Self.toolDefinitions)))
        case "tools/call":
            return self.callToolResponse(id: identifier, toolName: message.toolName, rawData: data,
                                         cancellation: cancellation)
        default:
            return Self.encode(Self.errorResponse(
                id: identifier,
                code: -32601,
                message: "Method not found: \(method)."
            ))
        }
    }

    private func callToolResponse(
        id: MCPJSONValue, toolName: String?, rawData: Data, cancellation: AutomationRequestCancellation?
    ) -> String {
        let isAwait = toolName == AutomationCommand.awaitTranscript.rawValue
        let identity = isAwait ? Self.awaitIdentity(in: rawData) : nil
        if isAwait, identity == nil {
            return Self.encode(Self.errorResponse(
                id: nil, code: -32600, message: "Await requires a string or 64-bit integer JSON-RPC ID."))
        }
        guard let name = toolName else {
            return Self.encode(Self.errorResponse(id: id, code: -32602, message: "tools/call requires a \"name\"."))
        }
        // The accepted surface must equal the advertised tool surface.
        guard let command = AutomationCommand(rawValue: name), Self.advertisedToolNames.contains(name) else {
            return Self.encode(Self.errorResponse(id: id, code: -32602, message: "Unknown tool: \(name)."))
        }
        let result = self.callTool(
            command, id: id, message: rawData, cancellation: cancellation, awaitIdentity: identity
        )
        return Self.encode(JSONRPCResponse(id: id, result: result))
    }

    // MARK: - Handlers

    private var initializeResult: MCPInitializeResult {
        MCPInitializeResult(
            protocolVersion: Self.protocolVersion,
            capabilities: .init(tools: .init(listChanged: false)),
            serverInfo: .init(name: Self.serverName, version: self.version),
            instructions: "Dictation and transcription tools backed by the running "
                + "Just Speak To It app. The app owns provider credentials; this server never sees them."
        )
    }

    /// Tool-level failures are results, not protocol errors: the agent should
    /// see them as content it can reason about and retry.
    private func callTool(
        _ command: AutomationCommand, id: MCPJSONValue, message: Data, cancellation: AutomationRequestCancellation?,
        awaitIdentity: String?
    ) -> MCPToolResult {
        do {
            let arguments = try AutomationToolArguments.decode(toolCall: message)
            let request = try self.request(for: command, arguments: arguments, callID: id, awaitIdentity: awaitIdentity)
            let response: AutomationResponse
            if command == .awaitTranscript {
                guard let client = self.client as? any CancellableAutomationRequesting else {
                    throw AutomationError(code: .unsupportedCommand,
                                          message: "This transport cannot cancel named capture waits. Update the CLI.")
                }
                response = try client.send(request, cancellation: cancellation ?? AutomationRequestCancellation())
            } else {
                response = try self.client.send(request)
            }
            if response.ok, let result = response.result {
                return Self.toolResult(for: result, command: command, isError: false)
            }
            let error = response.error
                ?? AutomationError(code: .internalError, message: "The app reported a failure without a reason.")
            return Self.toolFailure(error)
        } catch let error as AutomationError {
            return Self.toolFailure(error)
        } catch {
            return Self.toolFailure(AutomationError(code: .internalError, message: "Automation call failed."))
        }
    }

    private func request(
        for command: AutomationCommand, arguments: AutomationToolArguments, callID: MCPJSONValue, awaitIdentity: String?
    ) throws -> AutomationRequest {
        let identifier = try Self.socketRequestID(command: command, callID: callID, awaitIdentity: awaitIdentity)
        var arguments = arguments
        // The app resolves paths in its own working directory.
        arguments.path = arguments.path.map { CommandLineParser.absolutePath(for: $0) }
        return try arguments.request(id: identifier, command: command).validated()
    }

    private static func socketRequestID(
        command: AutomationCommand, callID: MCPJSONValue, awaitIdentity: String?
    ) throws -> String {
        if command == .awaitTranscript {
            guard let awaitIdentity else {
                throw AutomationError(code: .invalidArgument, message: "Await requires a typed JSON-RPC ID.")
            }
            return try Self.awaitRequestID(for: awaitIdentity)
        } else {
            return Self.requestID(for: callID)
        }
    }

    /// Distinguishes this MCP server process from every other client of the
    /// socket. JSON-RPC call ids restart at `1` for each agent session, so
    /// without a per-process scope two unrelated sessions would collide on the
    /// app's idempotency cache.
    private static let processScope = String(UUID().uuidString.prefix(8))

    /// Derives the idempotency key from the JSON-RPC call id, so an agent that
    /// retries a timed-out `start_dictation` cannot open a second session.
    static func requestID(for callID: MCPJSONValue) -> String {
        let raw: String
        switch callID {
        case .string(let text): raw = text
        case .integer(let number): raw = String(number)
        case .unsigned(let number): raw = String(number)
        case .double(let number): raw = String(number)
        case .null, .bool, .array, .object: raw = UUID().uuidString
        }
        let scoped = "mcp-" + Self.processScope + "-" + raw
        return String(scoped.prefix(AutomationLimits.maxIdentifierLength))
    }

    // MARK: - Payloads

    static func toolResult(for result: AutomationResult, command: AutomationCommand, isError: Bool) -> MCPToolResult {
        MCPToolResult(
            text: Self.summary(for: result, command: command), isError: isError,
            structuredContent: Self.structuredContent(for: result)
        )
    }

    private static func summary(for result: AutomationResult, command: AutomationCommand) -> String {
        let text = CLIRunner.humanText(for: result, command: command)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = text.isEmpty && command == .speakText ? "Spoke the text aloud." : text
        return result.notice.map { summary + "\n" + $0 } ?? summary
    }

    static func toolFailure(_ error: AutomationError) -> MCPToolResult {
        MCPToolResult(text: "\(error.code.rawValue): \(error.message)", isError: true)
    }

    /// The CLI's `--json` `data` object, kept as an `MCPJSONValue` so a count of
    /// 1 stays a number on Windows.
    private static func structuredContent(for result: AutomationResult) -> MCPJSONValue? {
        guard let data = try? AutomationCoding.encoder().encode(result),
              let value = try? JSONDecoder().decode(MCPJSONValue.self, from: data),
              case .object = value else {
            return nil
        }
        return value
    }

    /// Names from `toolDefinitions`, derived rather than restated so the two
    /// cannot drift.
    static let advertisedToolNames: Set<String> = Set(Self.toolDefinitions.map(\.name))

    // MARK: - JSON-RPC scaffolding

    static func errorResponse(id: MCPJSONValue?, code: Int, message: String) -> JSONRPCResponse<MCPJSONValue> {
        JSONRPCResponse(id: id, error: JSONRPCError(code: code, message: message))
    }

    static func encode<Message: Encodable>(_ message: Message) -> String {
        MCPJSONRPCWriter.line(message)
    }
}

extension AutomationCommand {
    /// The history command is named `get_history` on the wire and as an MCP tool;
    /// this alias keeps the tool table readable next to the other raw values.
    static var getHistoryToolName: String {
        AutomationCommand.history.rawValue
    }
}
