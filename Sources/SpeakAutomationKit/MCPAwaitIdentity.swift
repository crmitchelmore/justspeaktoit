import Foundation
import SpeakCore
#if canImport(CryptoKit)
import CryptoKit
#endif

extension MCPRequestHandler {
    private static let awaitProcessScope = UUID().uuidString

    /// Validate syntax, then use the original token: even Int64 decoding can round a fractional ID.
    static func awaitIdentity(in data: Data, cancellation: Bool = false) -> String? {
        guard data.count <= AutomationLimits.maxFrameBytes,
              let message = try? JSONDecoder().decode(MCPJSONValue.self, from: data),
              case .object = message else { return nil }
        var raw = MCPAwaitRawIdentity(validatedData: data)
        return raw.identity(cancellation: cancellation)
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
