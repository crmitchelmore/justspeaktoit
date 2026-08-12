import Foundation

/// Optional transport features, negotiated in `HelloMessage`.
///
/// Decoded leniently: an unknown capability from a newer peer maps to `.unknown`
/// rather than failing the whole handshake.
public enum TransportCapability: RawRepresentable, Codable, Sendable, Equatable {
    case automation
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "automation": self = .automation
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .automation: return "automation"
        case .unknown(let value): return value
        }
    }
}
