import Foundation
import SpeakCore

/// The arguments an automation command takes, under the names the MCP tools'
/// input schemas use. MCP `tools/call` decodes them from JSON and the CLI fills
/// them from flags; both then build the wire request through `apply(to:)`, so
/// the two front ends cannot type or route an argument differently.
public struct AutomationToolArguments: Codable, Equatable, Sendable {
    public var path: String?
    public var limit: Int?
    public var timeoutSeconds: TimeInterval?
    public var captureID: String?
    public var sinceID: String?
    public var text: String?
    public var voice: String?
    public var provider: String?
    public var model: String?
    public var quality: String?
    public var language: String?
    public var speed: Double?
    public var pitch: Double?
    public var play: Bool?

    public init() {}

    /// The MCP argument names, which are also the input schema property names.
    public enum CodingKeys: String, CodingKey, CaseIterable, Sendable {
        case captureID = "capture_id"
        case sinceID = "since_id"
        case path
        case text, voice, provider, model, quality, language
        case speed, pitch
        case play
        case limit
        case timeoutSeconds = "timeout_seconds"
    }

    /// Decodes in the order the arguments were always checked, so the first
    /// wrongly typed argument names itself. Unknown arguments are ignored; an
    /// explicit `null` is a wrongly typed argument, not an omitted one.
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        let identifiers = "Capture and cursor must be UUID strings."
        self.captureID = try fields.argument(String.self, .captureID, identifiers)
        self.sinceID = try fields.argument(String.self, .sinceID, identifiers)
        self.path = try fields.argument(String.self, .path, "must be a string")
        self.text = try fields.argument(String.self, .text, "must be a string")
        self.voice = try fields.argument(String.self, .voice, "must be a string")
        self.provider = try fields.argument(String.self, .provider, "must be a string")
        self.model = try fields.argument(String.self, .model, "must be a string")
        self.quality = try fields.argument(String.self, .quality, "must be a string")
        self.language = try fields.argument(String.self, .language, "must be a string")
        self.speed = try fields.argument(Double.self, .speed, "must be a number")
        self.pitch = try fields.argument(Double.self, .pitch, "must be a number")
        self.play = try fields.argument(Bool.self, .play, "must be a boolean")
        self.limit = try fields.argument(Int.self, .limit, "must be an integer")
        let timeout = "must be a positive number"
        self.timeoutSeconds = try fields.argument(TimeInterval.self, .timeoutSeconds, timeout)
        if let seconds = self.timeoutSeconds, !(seconds > 0) {
            throw AutomationError(code: .invalidArgument, message: "\"timeout_seconds\" \(timeout).")
        }
    }

    /// Copies every argument given onto `request`, leaving the rest unchanged.
    public func apply(to request: inout AutomationRequest) {
        let strings: [(KeyPath<Self, String?>, WritableKeyPath<AutomationRequest, String?>)] = [
            (\.path, \.path), (\.captureID, \.captureID), (\.sinceID, \.sinceID), (\.text, \.text),
            (\.voice, \.voice), (\.provider, \.provider), (\.model, \.model), (\.quality, \.quality),
            (\.language, \.language)
        ]
        for (argument, field) in strings { if let value = self[keyPath: argument] { request[keyPath: field] = value } }
        let numbers: [(KeyPath<Self, Double?>, WritableKeyPath<AutomationRequest, Double?>)] = [
            (\.timeoutSeconds, \.timeout), (\.speed, \.speed), (\.pitch, \.pitch)
        ]
        for (argument, field) in numbers { if let value = self[keyPath: argument] { request[keyPath: field] = value } }
        if let limit { request.limit = limit }
        if let play { request.play = play }
    }

    /// The request for `command` carrying these arguments.
    public func request(id: String, command: AutomationCommand) -> AutomationRequest {
        var request = AutomationRequest(id: id, command: command)
        self.apply(to: &request)
        return request
    }
}

extension AutomationToolArguments {
    /// The `params.arguments` object of one JSON-RPC `tools/call` message. A
    /// missing or non-object `arguments` means no arguments, as it always has.
    static func decode(toolCall message: Data) throws -> AutomationToolArguments {
        do {
            return try JSONDecoder().decode(ToolCall.self, from: message).arguments
        } catch let error as AutomationError {
            throw error
        } catch {
            throw AutomationError(code: .invalidArgument, message: "Tool arguments could not be read.")
        }
    }

    private struct ToolCall: Decodable {
        let arguments: AutomationToolArguments

        init(from decoder: Decoder) throws {
            let message = try decoder.container(keyedBy: ToolCallKey.self)
            guard let params = try? message.nestedContainer(keyedBy: ToolCallKey.self, forKey: .params),
                  (try? params.nestedContainer(keyedBy: AnyArgumentKey.self, forKey: .arguments)) != nil else {
                self.arguments = AutomationToolArguments()
                return
            }
            self.arguments = try params.decode(AutomationToolArguments.self, forKey: .arguments)
        }
    }
}

private enum ToolCallKey: String, CodingKey { case params, arguments }

/// Any argument name, used only to ask whether `arguments` is an object.
private struct AnyArgumentKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private extension KeyedDecodingContainer where Key == AutomationToolArguments.CodingKeys {
    /// One present argument of `type`, or nil when it is absent. A wrong type
    /// becomes the invalid-argument error MCP callers see as a tool failure.
    func argument<Value: Decodable>(_ type: Value.Type, _ key: Key, _ requirement: String) throws -> Value? {
        guard self.contains(key) else { return nil }
        do {
            return try self.decode(type, forKey: key)
        } catch {
            let message = requirement.hasSuffix(".") ? requirement : "\"\(key.rawValue)\" \(requirement)."
            throw AutomationError(code: .invalidArgument, message: message)
        }
    }
}
