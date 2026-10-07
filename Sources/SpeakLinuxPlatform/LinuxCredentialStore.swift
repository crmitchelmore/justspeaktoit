import Foundation
import CLinuxSupport

/// Provider API keys in the Secret Service keyring (GNOME Keyring, KWallet,
/// or the Secret portal inside Flatpak), keyed by the same canonical
/// credential identifiers Windows and Apple use.
public enum LinuxCredentialStore {
    /// The saved key, or "" when none is saved.
    public static func read(name: String) throws -> String {
        var buffer = [UInt8](repeating: 0, count: 8192)
        defer { _ = buffer.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        var count = 0
        let result = try LinuxNative.checked(accepting: [1]) { error, capacity in
            jsti_credential_read(name, &buffer, buffer.count, &count, error, capacity)
        }
        if result == 1 { return "" }
        guard let key = String(bytes: buffer.prefix(count), encoding: .utf8) else {
            throw LinuxNativeError(message: "The saved API key is not valid UTF-8. Save it again.")
        }
        return key
    }

    /// Saves `key` after trimming whitespace; an empty key removes the saved one.
    public static func save(_ key: String, name: String) throws {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            try LinuxNative.call { jsti_credential_delete(name, $0, $1) }
            return
        }
        try Array(cleaned.utf8).withUnsafeBufferPointer { bytes in
            try LinuxNative.call { jsti_credential_write(name, bytes.baseAddress, bytes.count, $0, $1) }
        }
    }
}
