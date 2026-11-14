import Foundation
import SpeakCore

/// What the desktop receiver keeps between launches.
///
/// `enabled` lives here rather than in `settings.json`, so a restored Mac
/// backup or a settings import can never open a network listener.
package struct DesktopTransportReceiverState: Codable, Equatable, Sendable {
    package var enabled = false
    package var pairing = TransportReceiverPairingState()

    package init(enabled: Bool = false, pairing: TransportReceiverPairingState = .init()) {
        self.enabled = enabled
        self.pairing = pairing
    }
}

/// Keeps the receiver state in a file sealed under a key from the platform
/// credential vault (Windows Credential Manager or the Secret Service), so
/// the device credentials on disk are useless without the user's keyring.
package final class DesktopTransportReceiverStorage: @unchecked Sendable {
    /// The vault entry holding the base64 sealing key.
    package static let credentialName = "transport.receiverStateKey"

    private let fileURL: URL
    private let readKey: @Sendable () throws -> Data?
    private let writeKey: @Sendable (Data) throws -> Void
    private let lock = NSLock()
    private var key: Data?
    private var state = DesktopTransportReceiverState()

    package init(
        fileURL: URL,
        readKey: @escaping @Sendable () throws -> Data?,
        writeKey: @escaping @Sendable (Data) throws -> Void
    ) {
        self.fileURL = fileURL
        self.readKey = readKey
        self.writeKey = writeKey
    }

    /// Reads the saved state. Throws only when the vault cannot be used; a
    /// missing or unreadable file starts fresh, which forgets every phone.
    package func load() throws -> DesktopTransportReceiverState {
        let stored = try readKey()
        let key: Data
        if let stored, stored.count == TransportSealedState.keyByteCount {
            key = stored
        } else {
            key = TransportSealedState.makeKey()
            try writeKey(key)
        }
        let loaded = (try? Data(contentsOf: fileURL))
            .flatMap { TransportSealedState.open($0, key: key) }
            .flatMap { try? JSONDecoder().decode(DesktopTransportReceiverState.self, from: $0) }
        return lock.withLock {
            self.key = key
            state = loaded ?? DesktopTransportReceiverState()
            return state
        }
    }

    package var current: DesktopTransportReceiverState {
        lock.withLock { state }
    }

    /// Applies a change and writes the sealed file.
    package func update(_ change: (inout DesktopTransportReceiverState) -> Void) throws {
        try lock.withLock {
            change(&state)
            guard let key else { throw DesktopTransportError("The receiver's keyring entry is not loaded.") }
            let plaintext = try JSONEncoder().encode(state)
            guard let sealed = TransportSealedState.seal(plaintext, key: key) else {
                throw DesktopTransportError("The receiver's keyring entry is damaged.")
            }
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try sealed.write(to: fileURL, options: .atomic)
        }
    }
}
