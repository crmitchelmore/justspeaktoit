import Foundation

/// The Mac a phone or tablet is paired with for Send to Mac, and the device
/// credential that Mac issued.
///
/// Only one Mac is paired at a time. The credential is the only secret: the
/// pairing code is never stored, because after the first pairing the phone
/// must never present it again on its own (#1643).
public protocol SendToMacPairingStore: TransportCredentialStore {
    var pairedMacName: String? { get }
    func setPairedMacName(_ name: String?)
    /// Reads the persisted pairing. Call once before using the store.
    func load() async
}

/// Keeps the pairing for the lifetime of the store only. Tests use it.
public final class InMemorySendToMacPairingStore: SendToMacPairingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record = SendToMacPairingRecord()

    public init() {}

    public var pairedMacName: String? {
        self.lock.withLock { self.record.pairedMacName }
    }

    public func setPairedMacName(_ name: String?) {
        self.lock.withLock { self.record.pairedMacName = name }
    }

    public func load() async {}

    public func credential(forMac macName: String) -> TransportDeviceCredential? {
        self.lock.withLock { self.record.credentials[macName] }
    }

    public func save(_ credential: TransportDeviceCredential, forMac macName: String) {
        self.lock.withLock { self.record.credentials[macName] = credential }
    }

    public func removeCredential(forMac macName: String) {
        self.lock.withLock { _ = self.record.credentials.removeValue(forKey: macName) }
    }
}

/// Persists the pairing in the Keychain.
///
/// It uses its own Keychain item, apart from the API-key store, so neither the
/// configuration QR code nor iCloud key sync can ever carry the credential to
/// another device. Reads come from an in-memory copy loaded by `load()`; each
/// change is written through in order.
public final class KeychainSendToMacPairingStore: SendToMacPairingStore, @unchecked Sendable {
    static let identifier = "send-to-mac.pairing"
    private static let logger = SpeakLogger.logger(category: "SendToMac")

    public static let defaultConfiguration = SecureStorageConfiguration(
        service: "com.github.speakapp.send-to-mac",
        accessibility: .afterFirstUnlock
    )

    private let storage: SecureStorage
    private let lock = NSLock()
    private var record = SendToMacPairingRecord()
    private var lastWrite: Task<Void, Never>?

    public init(configuration: SecureStorageConfiguration = KeychainSendToMacPairingStore.defaultConfiguration) {
        self.storage = SecureStorage(configuration: configuration)
    }

    public func load() async {
        guard let stored = try? await self.storage.secret(identifier: Self.identifier),
              let decoded = try? JSONDecoder().decode(SendToMacPairingRecord.self, from: Data(stored.utf8))
        else { return }
        self.lock.withLock { self.record = decoded }
    }

    /// Waits until every change made so far has reached the Keychain.
    public func flush() async {
        let pending = self.lock.withLock { self.lastWrite }
        await pending?.value
    }

    public var pairedMacName: String? {
        self.lock.withLock { self.record.pairedMacName }
    }

    public func setPairedMacName(_ name: String?) {
        self.update { $0.pairedMacName = name }
    }

    public func credential(forMac macName: String) -> TransportDeviceCredential? {
        self.lock.withLock { self.record.credentials[macName] }
    }

    public func save(_ credential: TransportDeviceCredential, forMac macName: String) {
        self.update { $0.credentials[macName] = credential }
    }

    public func removeCredential(forMac macName: String) {
        self.update { _ = $0.credentials.removeValue(forKey: macName) }
    }

    private func update(_ change: (inout SendToMacPairingRecord) -> Void) {
        let storage = self.storage
        self.lock.withLock {
            change(&self.record)
            let snapshot = self.record
            let previous = self.lastWrite
            self.lastWrite = Task {
                await previous?.value
                await Self.write(snapshot, to: storage)
            }
        }
    }

    private static func write(_ record: SendToMacPairingRecord, to storage: SecureStorage) async {
        do {
            if record.isEmpty {
                try? await storage.removeSecret(identifier: Self.identifier)
            } else {
                let data = try JSONEncoder().encode(record)
                // JSONEncoder always emits UTF-8.
                guard let json = String(bytes: data, encoding: .utf8) else { return }
                try await storage.storeSecret(json, identifier: Self.identifier)
            }
        } catch {
            Self.logger.error("Could not save the Send to Mac pairing: \(error.localizedDescription, privacy: .public)")
        }
    }
}

struct SendToMacPairingRecord: Codable, Equatable, Sendable {
    var pairedMacName: String?
    var credentials: [String: TransportDeviceCredential] = [:]

    var isEmpty: Bool {
        self.pairedMacName == nil && self.credentials.isEmpty
    }
}
