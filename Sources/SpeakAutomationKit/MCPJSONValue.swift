import Foundation

/// A JSON value that remembers whether it was a boolean or a number.
///
/// `JSONSerialization` returns numbers as `NSNumber`, and outside Apple
/// platforms an `NSNumber` holding 0 or 1 also bridges to `Bool`. The Windows
/// and Linux writer tries `Bool` before `Int`, so re-serialising a parsed `1`
/// there writes `true`: an echoed JSON-RPC id of 0 or 1 would no longer match
/// its request, and structured content would turn counts into booleans. Values
/// that flow back out to an MCP client — the call id, and the structured copy of
/// a tool result — are rebuilt from this type, whose cases no platform's writer
/// can confuse. On Apple platforms the rebuilt values serialise byte for byte as
/// before.
enum MCPJSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case string(String)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])

    /// `JSONDecoder` never decodes a number as `Bool` or a boolean as a number,
    /// on any platform, so the order of attempts is what classifies a value.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MCPJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: MCPJSONValue].self))
        }
    }

    /// Plain Swift values that `JSONSerialization` writes back with the same JSON
    /// type on every platform.
    var foundationValue: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .integer(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.foundationValue)
        case .object(let members):
            return members.mapValues(\.foundationValue)
        }
    }

    /// A JSON-RPC id as `JSONSerialization` parsed it, as a value that is written
    /// back unchanged: a string, an integer, a fractional number or null. Other
    /// shapes are not valid ids and are answered with null.
    static func jsonRPCID(_ parsed: Any) -> Any {
        switch parsed {
        case let text as String:
            return text
        case is NSNull:
            return NSNull()
        case let number as Int64:
            return number
        case let number as UInt64:
            return number
        case let number as Double:
            return number
        default:
            return NSNull()
        }
    }
}
