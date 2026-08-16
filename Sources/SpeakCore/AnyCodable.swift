import Foundation

// MARK: - AnyCodable Helper

/// The bounded error domain for `AnyCodable` construction failures.
public enum AnyCodableError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The wrapped value is not representable as JSON
    /// (null, boolean, integer, double, string, array, or object).
    case unsupportedValue(typeName: String)

    public var description: String {
        switch self {
        case .unsupportedValue(let typeName):
            return "AnyCodable cannot represent value of type \(typeName) as JSON"
        }
    }
}

/// A type-erased Codable wrapper for heterogeneous JSON values.
///
/// Storage is a closed, recursively `Sendable` JSON value enum, so instances
/// are genuinely immutable and safe to share across concurrency domains.
/// Construction canonicalises input eagerly: Foundation containers (including
/// mutable ones such as `NSMutableDictionary`/`NSMutableArray`) are deep-copied
/// into value types, and anything that is not JSON-representable is rejected
/// with ``AnyCodableError`` at construction time rather than trapping or
/// failing later during encoding.
public struct AnyCodable: Codable, Equatable, Sendable {

    /// A closed, recursively Sendable representation of a JSON value.
    public enum JSONValue: Equatable, Sendable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])
    }

    /// The canonical, immutable JSON storage.
    public let storage: JSONValue

    /// The wrapped value bridged back to loosely typed JSON objects
    /// (`NSNull`, `Bool`, `Int`, `Double`, `String`, `[Any]`,
    /// `[String: Any]`), mirroring the historical `value` property.
    public var value: Any {
        Self.bridge(storage)
    }

    /// Wrap an already-canonical JSON value. Never fails.
    public init(_ storage: JSONValue) {
        self.storage = storage
    }

    /// Canonicalise an arbitrary value into JSON storage.
    ///
    /// Accepts `nil`/`NSNull`, booleans, integer and floating-point numbers,
    /// strings, and (recursively) arrays and string-keyed dictionaries of the
    /// same — including their mutable Foundation counterparts, which are
    /// deep-copied so later mutation of the original cannot be observed.
    ///
    /// - Throws: ``AnyCodableError/unsupportedValue(typeName:)`` for any
    ///   value that is not JSON-representable.
    public init(_ value: Any) throws {
        self.storage = try Self.canonicalise(value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.storage = .null
        } else if let bool = try? container.decode(Bool.self) {
            self.storage = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self.storage = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self.storage = .double(double)
        } else if let string = try? container.decode(String.self) {
            self.storage = .string(string)
        } else if let array = try? container.decode([AnyCodable].self) {
            self.storage = .array(array.map(\.storage))
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.storage = .object(dict.mapValues(\.storage))
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported type"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch storage {
        case .null:
            try container.encodeNil()
        case .bool(let bool):
            try container.encode(bool)
        case .int(let int):
            try container.encode(int)
        case .double(let double):
            try container.encode(double)
        case .string(let string):
            try container.encode(string)
        case .array(let array):
            try container.encode(array.map(AnyCodable.init(_:)))
        case .object(let object):
            try container.encode(object.mapValues(AnyCodable.init(_:)))
        }
    }

    // MARK: - Canonicalisation

    private static func canonicalise(_ value: Any) throws -> JSONValue {
        switch value {
        case Optional<Any>.none, is NSNull:
            return .null
        case let canonical as JSONValue:
            return canonical
        case let wrapped as AnyCodable:
            return wrapped.storage
        case let number as NSNumber:
            // Swift Bool/Int/Double (and friends) all bridge through NSNumber
            // on Darwin, so disambiguate via the underlying CF type instead of
            // `as?` casts, which would happily turn `true` into `1`.
            return canonicalise(number)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(try array.map(canonicalise))
        case let object as [String: Any]:
            return .object(try object.mapValues(canonicalise))
        default:
            throw AnyCodableError.unsupportedValue(typeName: String(describing: type(of: value)))
        }
    }

    private static func canonicalise(_ number: NSNumber) -> JSONValue {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .bool(number.boolValue)
        }
        if !CFNumberIsFloatType(number), let int = Int(exactly: number) {
            return .int(int)
        }
        return .double(number.doubleValue)
    }

    // MARK: - Bridging

    private static func bridge(_ storage: JSONValue) -> Any {
        switch storage {
        case .null:
            return NSNull()
        case .bool(let bool):
            return bool
        case .int(let int):
            return int
        case .double(let double):
            return double
        case .string(let string):
            return string
        case .array(let array):
            return array.map(bridge)
        case .object(let object):
            return object.mapValues(bridge)
        }
    }
}
