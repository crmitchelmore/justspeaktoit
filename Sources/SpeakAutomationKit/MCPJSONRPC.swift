import Foundation

/// One JSON-RPC 2.0 message as the MCP server reads it.
///
/// Every member keeps its JSON type, so the handler answers a malformed member
/// with the protocol error it deserves rather than a parse error, and the whole
/// message must be valid JSON before any member is read.
struct JSONRPCRequest: Decodable {
    /// Absent for a notification; `.null` when the message sent `"id": null`.
    let id: MCPJSONValue?
    let method: MCPJSONValue?
    let params: MCPJSONValue?

    init(from decoder: Decoder) throws {
        let members = try decoder.singleValueContainer().decode([String: MCPJSONValue].self)
        self.id = members["id"]
        self.method = members["method"]
        self.params = members["params"]
    }

    static func decode(_ data: Data) -> JSONRPCRequest? {
        try? JSONDecoder().decode(JSONRPCRequest.self, from: data)
    }

    var methodName: String? { self.method?.stringValue }
    /// The tool a `tools/call` names.
    var toolName: String? { self.params?["name"]?.stringValue }
}

/// One JSON-RPC 2.0 reply: a result or an error, never both.
struct JSONRPCResponse<Result: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: MCPJSONValue
    let result: Result?
    let error: JSONRPCError?

    init(id: MCPJSONValue?, result: Result) {
        self.id = id ?? .null
        self.result = result
        self.error = nil
    }
}

extension JSONRPCResponse where Result == MCPJSONValue {
    init(id: MCPJSONValue?, error: JSONRPCError) {
        self.id = id ?? .null
        self.result = nil
        self.error = error
    }
}

struct JSONRPCError: Encodable, Equatable {
    let code: Int
    let message: String
}

// MARK: - MCP payloads

struct MCPInitializeResult: Encodable {
    struct Capabilities: Encodable {
        let tools: MCPToolCapabilities
    }

    struct ServerInfo: Encodable {
        let name: String
        let version: String
    }

    let protocolVersion: String
    let capabilities: Capabilities
    let serverInfo: ServerInfo
    let instructions: String
}

struct MCPToolCapabilities: Encodable {
    let listChanged: Bool
}

struct MCPToolDefinition: Encodable {
    let name: String
    let description: String
    let inputSchema: MCPJSONValue
}

struct MCPToolList: Encodable {
    let tools: [MCPToolDefinition]
}

struct MCPToolResult: Encodable {
    struct Content: Encodable, Equatable {
        let type = "text"
        let text: String
    }

    let content: [Content]
    let isError: Bool
    /// The CLI's `--json` `data` object, when the call succeeded.
    let structuredContent: MCPJSONValue?

    init(text: String, isError: Bool, structuredContent: MCPJSONValue? = nil) {
        self.content = [Content(text: text)]
        self.isError = isError
        self.structuredContent = structuredContent
    }
}

/// An empty JSON object, the `ping` result.
struct MCPEmptyResult: Encodable {}

// MARK: - Writing

enum MCPJSONRPCWriter {
    static let encodingFailure = #"{"error":{"code":-32603,"message":"Encoding failure"},"id":null,"jsonrpc":"2.0"}"#

    /// One reply line with sorted keys.
    ///
    /// The value passes through `MCPJSONValue` so no platform's writer can turn a
    /// 0 or 1 into a boolean, and `JSONSerialization` writes it so every reply
    /// keeps the bytes it has always had: Foundation's encoder spells some
    /// doubles differently (`0.1` rather than `0.10000000000000001`).
    static func line<Message: Encodable>(_ message: Message) -> String {
        guard let encoded = try? JSONEncoder().encode(message),
              let value = try? JSONDecoder().decode(MCPJSONValue.self, from: encoded),
              let data = try? JSONSerialization.data(withJSONObject: value.foundationValue, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return Self.encodingFailure
        }
        return text
    }
}
