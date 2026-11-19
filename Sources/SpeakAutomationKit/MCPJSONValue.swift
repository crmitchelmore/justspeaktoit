import Foundation

/// A JSON value that remembers whether it was a boolean or a number.
///
/// `JSONSerialization` returns numbers as `NSNumber`, and outside Apple
/// platforms an `NSNumber` holding 0 or 1 also bridges to `Bool`. The Windows
/// and Linux writer tries `Bool` before `Int`, so re-serialising a parsed `1`
/// there writes `true`: an echoed JSON-RPC id of 0 or 1 would no longer match
/// its request, and structured content would turn counts into booleans. Every
/// message the MCP server reads or writes passes through this type, whose cases
/// no platform's writer can confuse.
enum MCPJSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsigned(UInt64)
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
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsigned(value)
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

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .unsigned(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let members): try container.encode(members)
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
        case .unsigned(let value):
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

    /// This value as a JSON-RPC id that is written back unchanged: a string, an
    /// integer, a fractional number or null. A whole number is an integer however
    /// it was spelt (`1.0`, `1e2`), and a boolean is answered as 0 or 1, as
    /// Foundation's number bridging always did. Other shapes are not valid ids
    /// and are answered with null.
    var jsonRPCID: MCPJSONValue {
        switch self {
        case .string, .integer, .unsigned, .null:
            return self
        case .bool(let value):
            return .integer(value ? 1 : 0)
        case .double(let value):
            if let integer = Int64(exactly: value) { return .integer(integer) }
            if let unsigned = UInt64(exactly: value) { return .unsigned(unsigned) }
            return self
        case .array, .object:
            return .null
        }
    }

    /// The text of a string value.
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    subscript(key: String) -> MCPJSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }
}

/// Literals keep the advertised tool schemas readable.
extension MCPJSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int64) { self = .integer(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: MCPJSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, MCPJSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
