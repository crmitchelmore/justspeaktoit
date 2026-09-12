import Foundation

/// A closed scalar value that can cross the product-analytics payload boundary.
///
/// Keeping this narrower than `AnyCodable` prevents call sites from attaching
/// arrays, objects, or other unreviewed structures while preserving JSON's
/// native string, Boolean, integer, and floating-point types.
public enum AnalyticsPropertyValue: Codable, Equatable, Sendable {
    case string(String)
    case boolean(Bool)
    case integer(Int)
    case double(Double)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        }
    }

    public var foundationValue: Any {
        switch self {
        case .string(let value): value
        case .boolean(let value): value
        case .integer(let value): value
        case .double(let value): value
        }
    }

    public var isEmpty: Bool {
        if case .string(let value) = self { return value.isEmpty }
        return false
    }

    public func contains(_ text: String) -> Bool {
        if case .string(let value) = self { return value.contains(text) }
        return false
    }
}

extension AnalyticsPropertyValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension AnalyticsPropertyValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .boolean(value) }
}

extension AnalyticsPropertyValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .integer(value) }
}

extension AnalyticsPropertyValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}
