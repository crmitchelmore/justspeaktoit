import CoreFoundation
import Foundation
import SpeakCore
#if canImport(CryptoKit)
import CryptoKit
#endif

extension MCPRequestHandler {
    private static let awaitProcessScope = UUID().uuidString

    static func validAwaitID(_ id: Any?) -> Bool {
        guard let id else { return false }
        if id is String { return true }
        guard let number = id as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.isFinite
    }

    /// Await-only identity: preserve the complete typed JSON-RPC ID without truncating or
    /// conflating numeric 1 with string "1". Existing verbs keep their original retry keys.
    static func awaitRequestID(for id: Any?) throws -> String {
        #if canImport(CryptoKit)
        guard Self.validAwaitID(id), let id,
              let data = try? JSONSerialization.data(withJSONObject: ["id": id], options: [.sortedKeys]) else {
            throw AutomationError(code: .invalidArgument, message: "Await requires a string or numeric JSON-RPC ID.")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "await-" + Self.awaitProcessScope + "-" + digest
        #else
        throw AutomationError(code: .unsupportedCommand, message: "Named capture await requires a compatible Mac app.")
        #endif
    }
}
