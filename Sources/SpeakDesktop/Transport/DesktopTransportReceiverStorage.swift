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
///
/// Loading writes nothing: the vault key, the folder and the file are created
/// by the first `update`, so a launch with the receiver off leaves no trace.
package final class DesktopTransportReceiverStorage: @unchecked Sendable {
    /// The vault entry holding the base64 sealing key.
    package static let credentialName = "transport.receiverStateKey"

    private let fileURL: URL
    private let readKey: @Sendable () throws -> Data?
    private let writeKey: @Sendable (Data) throws -> Void
    private let prepareDirectory: @Sendable (URL) throws -> Void
    private let lock = NSLock()
    private var key: Data?
    private var keyIsStored = false
    private var state = DesktopTransportReceiverState()

    package init(
        fileURL: URL,
        readKey: @escaping @Sendable () throws -> Data?,
        writeKey: @escaping @Sendable (Data) throws -> Void,
        prepareDirectory: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
        }
    ) {
        self.fileURL = fileURL
        self.readKey = readKey
        self.writeKey = writeKey
        self.prepareDirectory = prepareDirectory
    }

    /// Reads the saved state. Throws only when the vault cannot be used; a
    /// missing or unreadable file starts fresh, which forgets every phone.
    package func load() throws -> DesktopTransportReceiverState {
        let stored = try readKey()
        let isStored = stored?.count == TransportSealedState.keyByteCount
        let key = isStored ? stored ?? Data() : TransportSealedState.makeKey()
        let loaded = (try? Data(contentsOf: fileURL))
            .flatMap { TransportSealedState.open($0, key: key) }
            .flatMap { try? JSONDecoder().decode(DesktopTransportReceiverState.self, from: $0) }
        return lock.withLock {
            self.key = key
            keyIsStored = isStored
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
            if !keyIsStored {
                try writeKey(key)
                keyIsStored = true
            }
            try prepareDirectory(fileURL.deletingLastPathComponent())
            try sealed.write(to: fileURL, options: .atomic)
        }
    }
}
