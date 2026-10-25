import Foundation
import SpeakCore
#if canImport(CryptoKit)
import CryptoKit
#endif

extension MCPRequestHandler {
    private static let awaitProcessScope = UUID().uuidString

    /// Decode from the original bytes: Foundation NSNumber bridging can conflate booleans and
    /// numeric 0/1 on portable hosts. The existing typed JSON decoder preserves that distinction.
    static func awaitIdentity(in data: Data, cancellation: Bool = false) -> String? {
        guard let message = try? JSONDecoder().decode(MCPJSONValue.self, from: data),
              case .object(let fields) = message else { return nil }
        let identifier: MCPJSONValue?
        if cancellation {
            guard let parameters = fields["params"], case .object(let params) = parameters else { return nil }
            identifier = params["requestId"]
        } else {
            identifier = fields["id"]
        }
        switch identifier {
        case .string(let value)?: return "s:" + value
        case .integer(let value)?: return "n:" + String(value)
        case .unsigned(let value)?: return "n:" + String(value)
        case .double(let value)? where value.isFinite && value.rounded(.towardZero) != value:
            // Exact integers were decoded above. Reject integral Double fallback: an oversized
            // integer can round into Int64.min or another caller's ID. Use a string for larger IDs.
            return "n:" + String(value)
        default: return nil
        }
    }

    /// Await-only identity: preserve the complete typed JSON-RPC ID without truncating.
    /// Existing verbs keep their original retry keys. Only validated raw identities reach this helper.
    static func awaitRequestID(for identity: String) throws -> String {
        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "await-" + Self.awaitProcessScope + "-" + digest
        #else
        throw AutomationError(code: .unsupportedCommand, message: "Named capture await requires a compatible Mac app.")
        #endif
    }
}
