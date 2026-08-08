// swiftlint:disable file_length
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import Security

// MARK: - Settings Sync using iCloud Key-Value Store

/// Syncs non-secret preferences across devices using iCloud Key-Value Store.
/// For secrets/API keys, use SecureStorage with synchronizable=true.
/// 
/// NOTE: iCloud sync requires an Apple Developer subscription with iCloud entitlement.
/// Without it, this class fails gracefully - all operations become no-ops and
/// availability checks return false. Local settings still work via UserDefaults fallback.
public final class SettingsSync: @unchecked Sendable {
    public static let shared = SettingsSync()
    
    /// Whether iCloud KV store is available (requires Apple Developer subscription)
    public private(set) var isAvailable: Bool = false
    
    private var store: NSUbiquitousKeyValueStore?
    private let localStorage = UserDefaults.standard
    private let notificationCenter: NotificationCenter
    
    /// Keys that should be synced
    public enum SyncKey: String, CaseIterable {
        case selectedModel = "sync.selectedModel"
        case autoStartRecording = "sync.autoStartRecording"
        case showConfidenceScore = "sync.showConfidenceScore"
        case hapticFeedback = "sync.hapticFeedback"
        case darkModePreference = "sync.darkModePreference"
        case lastSyncTimestamp = "sync.lastSyncTimestamp"
    }
    
    /// Notification posted when remote settings change
    public static let didReceiveRemoteChangesNotification = Notification.Name("SettingsSyncDidReceiveRemoteChanges")
    
    private init() {
        self.notificationCenter = NotificationCenter.default
        
        // Check if iCloud is available before trying to use it
        if FileManager.default.ubiquityIdentityToken != nil {
            self.store = NSUbiquitousKeyValueStore.default
            self.isAvailable = true
            
            // Listen for remote changes
            notificationCenter.addObserver(
                self,
                selector: #selector(storeDidChange(_:)),
                name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: store
            )
            
            // Start syncing
            store?.synchronize()
        } else {
            // iCloud not available - use local storage fallback
            self.store = nil
            self.isAvailable = false
            print("[SettingsSync] iCloud not available - using local storage only")
        }
    }
    
    deinit {
        notificationCenter.removeObserver(self)
    }
    
    // MARK: - Public API
    
    /// Stores a string value for the given key (falls back to local storage if iCloud unavailable)
    public func set(_ value: String?, forKey key: SyncKey) {
        if let store = store {
            store.set(value, forKey: key.rawValue)
            store.set(Date().timeIntervalSince1970, forKey: SyncKey.lastSyncTimestamp.rawValue)
            store.synchronize()
        } else {
            // Fallback to local storage
            localStorage.set(value, forKey: key.rawValue)
        }
    }
    
    /// Stores a boolean value for the given key (falls back to local storage if iCloud unavailable)
    public func set(_ value: Bool, forKey key: SyncKey) {
        if let store = store {
            store.set(value, forKey: key.rawValue)
            store.set(Date().timeIntervalSince1970, forKey: SyncKey.lastSyncTimestamp.rawValue)
            store.synchronize()
        } else {
            localStorage.set(value, forKey: key.rawValue)
        }
    }
    
    /// Retrieves a string value for the given key
    public func string(forKey key: SyncKey) -> String? {
        if let store = store {
            return store.string(forKey: key.rawValue)
        } else {
            return localStorage.string(forKey: key.rawValue)
        }
    }
    
    /// Retrieves a boolean value for the given key
    public func bool(forKey key: SyncKey) -> Bool {
        if let store = store {
            return store.bool(forKey: key.rawValue)
        } else {
            return localStorage.bool(forKey: key.rawValue)
        }
    }
    
    /// Forces a sync with iCloud (no-op if iCloud unavailable)
    public func synchronize() -> Bool {
        store?.synchronize() ?? true
    }
    
    /// Gets the timestamp of the last sync (nil if iCloud unavailable)
    public var lastSyncDate: Date? {
        guard let store = store else { return nil }
        let timestamp = store.double(forKey: SyncKey.lastSyncTimestamp.rawValue)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
    
    // MARK: - Private
    
    @objc private func storeDidChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        else { return }
        
        switch reason {
        case NSUbiquitousKeyValueStoreServerChange,
             NSUbiquitousKeyValueStoreInitialSyncChange:
            // Post notification for UI to update
            notificationCenter.post(name: Self.didReceiveRemoteChangesNotification, object: self)
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            print("[SettingsSync] iCloud KV store quota exceeded")
        case NSUbiquitousKeyValueStoreAccountChange:
            print("[SettingsSync] iCloud account changed")
        default:
            break
        }
    }
}

// MARK: - QR Code Configuration Transfer

/// Enables transferring API keys and configuration via QR code when iCloud sync is unavailable.
public struct ConfigTransferPayload: Codable {
    public var version: Int = 1
    public var timestamp: Date
    public var secrets: [String: String]
    public var settings: [String: String]
    
    public init(secrets: [String: String] = [:], settings: [String: String] = [:]) {
        self.timestamp = Date()
        self.secrets = secrets
        self.settings = settings
    }
}

/// The encrypted container a QR code actually carries.
///
/// Only `ciphertext` holds credentials; `version`, `createdAt` and `salt` are
/// public metadata, but all three are authenticated as additional data, so a
/// tampered version or back-dated `createdAt` fails decryption rather than
/// silently changing how the payload is interpreted.
public struct ConfigTransferEnvelope: Codable, Equatable, Sendable {
    /// Current envelope version. v0 is the legacy XOR-obfuscated format, which
    /// has no envelope at all and is only accepted on import.
    public static let currentVersion = 1

    public let version: Int
    public let createdAt: Date
    public let salt: Data
    public let nonce: Data
    /// AES-GCM ciphertext with the 16-byte authentication tag appended.
    public let ciphertext: Data

    public init(version: Int, createdAt: Date, salt: Data, nonce: Data, ciphertext: Data) {
        self.version = version
        self.createdAt = createdAt
        self.salt = salt
        self.nonce = nonce
        self.ciphertext = ciphertext
    }
}

/// A generated transfer: the QR payload plus the one-time code the exporting
/// device shows on screen. The code is never part of the payload — the user
/// carries it to the importing device by reading and typing it.
public struct ConfigTransfer: Equatable, Sendable {
    public let payload: String
    public let code: String

    public init(payload: String, code: String) {
        self.payload = payload
        self.code = code
    }

    /// The code split into two groups for display, e.g. `A1B2-C3D4`.
    public var formattedCode: String {
        ConfigTransferCode.formatted(code)
    }
}

/// The one-time code that protects a transfer.
///
/// Uses Crockford Base32, whose alphabet omits `I`, `L`, `O` and `U`, so the
/// characters a user is most likely to mistype have a single defined meaning
/// (`I`/`l` → `1`, `O` → `0`). Eight characters give 40 bits of entropy, which
/// combined with PBKDF2 stretching and the 10-minute expiry keeps an offline
/// attack on a captured QR code impractical.
public enum ConfigTransferCode {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let length = 8

    /// Generates a fresh code from the system CSPRNG. Each character consumes a
    /// random byte masked to 5 bits, so the 32-character alphabet is sampled
    /// uniformly with no modulo bias.
    public static func generate() throws -> String {
        guard let bytes = KeyDerivation.randomBytes(count: length) else {
            throw ConfigTransferError.randomGenerationFailed
        }
        return String(bytes.map { alphabet[Int($0 & 0x1F)] })
    }

    /// Canonicalises a typed code: case-insensitive, tolerant of the separators
    /// and spaces users copy from the display, and mapping the Crockford
    /// look-alike characters onto their intended digits.
    public static func normalize(_ raw: String) throws -> String {
        var normalized = ""
        for character in raw.uppercased() {
            switch character {
            case "-", " ", "\u{2013}", "\u{2014}", "\t", "\n":
                continue
            case "I", "L":
                normalized.append("1")
            case "O":
                normalized.append("0")
            default:
                guard alphabet.contains(character) else {
                    throw ConfigTransferError.invalidCode
                }
                normalized.append(character)
            }
        }
        guard normalized.count == length else {
            throw ConfigTransferError.invalidCode
        }
        return normalized
    }

    /// Formats a code for display as two four-character groups.
    public static func formatted(_ code: String) -> String {
        guard code.count == length else { return code }
        let midpoint = code.index(code.startIndex, offsetBy: length / 2)
        return "\(code[code.startIndex..<midpoint])-\(code[midpoint...])"
    }
}

/// Handles encoding/decoding of configuration for QR transfer.
///
/// Sendable: the only stored property is an immutable `Int`; JSON coders are
/// created per call (QR transfer is rare, so the allocation is irrelevant).
public final class ConfigTransferManager: Sendable {
    public static let shared = ConfigTransferManager()

    /// How long a generated QR code stays importable. Checked with an absolute
    /// difference, so the same window doubles as the tolerance for clock skew
    /// between the two devices: a payload whose `createdAt` is up to 10 minutes
    /// in the *future* (importing device's clock running behind) is still
    /// accepted, anything beyond that is rejected as expired.
    public static let defaultMaxAge: TimeInterval = 600

    private static let keyByteCount = 32
    private static let saltByteCount = 16
    /// OWASP's current PBKDF2-SHA256 guidance, and the same cost the CloudKit
    /// key sync uses.
    static let productionPBKDF2Iterations = 210_000
    private static let keyDerivationInfo = Data("justspeaktoit.config-transfer.v1".utf8)

    /// The PBKDF2 cost is what makes an 8-character code safe against offline
    /// guessing, so it stays at the production value everywhere except tests
    /// that only exercise the surrounding logic.
    let pbkdf2Iterations: Int

    private var encoder: JSONEncoder { Self.makeCoderEncoder() }
    private var decoder: JSONDecoder { Self.makeCoderDecoder() }
    private var envelopeEncoder: JSONEncoder { Self.makeCoderEncoder() }
    private var envelopeDecoder: JSONDecoder { Self.makeCoderDecoder() }

    private static func makeCoderEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeCoderDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    init(pbkdf2Iterations: Int = ConfigTransferManager.productionPBKDF2Iterations) {
        self.pbkdf2Iterations = pbkdf2Iterations
    }

    /// API-key identifiers included in a device-to-device transfer: the union
    /// of the keys either platform can hold, so exporting from one platform
    /// and importing on the other never silently drops a stored credential.
    public static let transferableSecretIdentifiers: [String] = [
        "deepgram.apiKey",
        "openrouter.apiKey",
        "openai.apiKey",
        "openai.tts.apiKey",
        "elevenlabs.apiKey",
        "azure.speech.apiKey"
    ]

    /// Collects the transferable secrets currently stored in `storage`,
    /// skipping identifiers that are missing or empty.
    ///
    /// Only `SecureStorageError.valueNotFound` is treated as "not stored".
    /// Access-denied, corruption and other Keychain failures are rethrown: a
    /// transfer that silently omits a credential the user believes they exported
    /// is worse than one that fails visibly.
    public func gatherSecrets(storage: SecureStorage) async throws -> [String: String] {
        var secrets: [String: String] = [:]
        for identifier in Self.transferableSecretIdentifiers {
            do {
                let value = try await storage.secret(identifier: identifier)
                if !value.isEmpty {
                    secrets[identifier] = value
                }
            } catch SecureStorageError.valueNotFound {
                continue
            }
        }
        return secrets
    }

    /// Gathers the non-secret settings included in a transfer. The payload
    /// always uses the shared `selectedModel` key; `liveModelDefaultsKey`
    /// names the local UserDefaults key the calling platform stores its live
    /// transcription model under.
    public func gatherSettings(
        defaults: UserDefaults = .standard,
        liveModelDefaultsKey: String = "selectedModel"
    ) -> [String: String] {
        var settings: [String: String] = [:]
        if let model = defaults.string(forKey: liveModelDefaultsKey) {
            settings["selectedModel"] = model
        }
        return settings
    }

    /// Builds the QR code image for an encoded payload, scaled up for crisp
    /// on-screen display. Callers wrap the `CIImage` in the platform image
    /// type (NSImage/UIImage).
    public func makeQRCodeImage(payload: String, scale: CGFloat = 10) -> CIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        return outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    // MARK: - Export

    /// Builds an encrypted QR payload together with the one-time code that
    /// unlocks it. The exporting device displays the code beside the QR; it is
    /// never encoded into the QR, so scanning the image alone reveals nothing.
    public func makeTransfer(
        secrets: [String: String],
        settings: [String: String]
    ) throws -> ConfigTransfer {
        let code = try ConfigTransferCode.generate()
        let payload = try generatePayload(secrets: secrets, settings: settings, code: code)
        return ConfigTransfer(payload: payload, code: code)
    }

    /// Encrypts a payload under `code` and returns the base64 QR string.
    ///
    /// `createdAt` is truncated to whole seconds so it survives the envelope's
    /// ISO-8601 encoding unchanged — it is authenticated, and a value that
    /// re-encoded differently would break decryption on the other device.
    public func generatePayload(
        secrets: [String: String],
        settings: [String: String],
        code: String,
        createdAt: Date = Date()
    ) throws -> String {
        let normalizedCode = try ConfigTransferCode.normalize(code)
        let payload = ConfigTransferPayload(secrets: secrets, settings: settings)
        let plaintext = try encoder.encode(payload)

        guard let salt = KeyDerivation.randomBytes(count: Self.saltByteCount) else {
            throw ConfigTransferError.randomGenerationFailed
        }
        let timestamp = Date(timeIntervalSince1970: (createdAt.timeIntervalSince1970).rounded(.down))
        let key = deriveKey(code: normalizedCode, salt: salt)
        let nonce = AES.GCM.Nonce()
        let authenticatedData = Self.authenticatedData(
            version: ConfigTransferEnvelope.currentVersion,
            createdAt: timestamp,
            salt: salt
        )

        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(
                plaintext,
                using: key,
                nonce: nonce,
                authenticating: authenticatedData
            )
        } catch {
            throw ConfigTransferError.encryptionFailed
        }

        let envelope = ConfigTransferEnvelope(
            version: ConfigTransferEnvelope.currentVersion,
            createdAt: timestamp,
            salt: salt,
            nonce: Data(nonce),
            ciphertext: sealedBox.ciphertext + sealedBox.tag
        )
        return try envelopeEncoder.encode(envelope).base64EncodedString()
    }

    // MARK: - Import

    /// Inspects a scanned string without decrypting it, so the importing UI
    /// knows whether to ask for a one-time code. Unknown envelope versions are
    /// rejected here rather than being mistaken for a legacy payload.
    public func format(of encoded: String) throws -> ConfigTransferFormat {
        guard let data = Data(base64Encoded: encoded), !data.isEmpty else {
            throw ConfigTransferError.invalidFormat
        }

        if let probe = try? envelopeDecoder.decode(EnvelopeVersionProbe.self, from: data) {
            guard probe.version == ConfigTransferEnvelope.currentVersion else {
                throw ConfigTransferError.unsupportedVersion(probe.version)
            }
            return .encrypted
        }

        guard (try? decoder.decode(ConfigTransferPayload.self, from: deobfuscate(data: data))) != nil else {
            throw ConfigTransferError.decodingFailed
        }
        return .legacy
    }

    /// Decrypts a scanned payload with the code the user typed.
    ///
    /// Every failure mode is distinct and non-partial: an unknown version, an
    /// expired code, a wrong/tampered payload and a malformed code each throw
    /// before any credential is returned, so a caller can never apply half a
    /// transfer.
    public func decodePayload(
        _ encoded: String,
        code: String,
        maxAge: TimeInterval = ConfigTransferManager.defaultMaxAge,
        now: Date = Date()
    ) throws -> ConfigTransferPayload {
        let normalizedCode = try ConfigTransferCode.normalize(code)
        let envelope = try decodeEnvelope(encoded)

        guard abs(envelope.createdAt.timeIntervalSince(now)) < maxAge else {
            throw ConfigTransferError.payloadExpired
        }

        let key = deriveKey(code: normalizedCode, salt: envelope.salt)
        let authenticatedData = Self.authenticatedData(
            version: envelope.version,
            createdAt: envelope.createdAt,
            salt: envelope.salt
        )

        let tagByteCount = 16
        guard envelope.ciphertext.count > tagByteCount else {
            throw ConfigTransferError.decodingFailed
        }
        let splitIndex = envelope.ciphertext.index(envelope.ciphertext.endIndex, offsetBy: -tagByteCount)

        let plaintext: Data
        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: envelope.nonce),
                ciphertext: envelope.ciphertext[..<splitIndex],
                tag: envelope.ciphertext[splitIndex...]
            )
            plaintext = try AES.GCM.open(sealedBox, using: key, authenticating: authenticatedData)
        } catch {
            // AES-GCM cannot distinguish a wrong code from a tampered payload,
            // and neither should the caller: both mean "do not import this".
            throw ConfigTransferError.authenticationFailed
        }

        do {
            return try decoder.decode(ConfigTransferPayload.self, from: plaintext)
        } catch {
            throw ConfigTransferError.decodingFailed
        }
    }

    /// Parses (but does not decrypt) the envelope, rejecting unknown versions.
    public func decodeEnvelope(_ encoded: String) throws -> ConfigTransferEnvelope {
        guard let data = Data(base64Encoded: encoded), !data.isEmpty else {
            throw ConfigTransferError.invalidFormat
        }
        guard let envelope = try? envelopeDecoder.decode(ConfigTransferEnvelope.self, from: data) else {
            throw ConfigTransferError.decodingFailed
        }
        guard envelope.version == ConfigTransferEnvelope.currentVersion else {
            throw ConfigTransferError.unsupportedVersion(envelope.version)
        }
        return envelope
    }

    /// **Deprecated.** Reads a pre-encryption QR payload (XOR + base64, no
    /// envelope, no code).
    ///
    /// Import-only, and only because a device still displaying a QR from an
    /// older build should not become un-importable. The format offers no
    /// confidentiality at all against anyone who photographs the code, so
    /// exports always use the encrypted envelope and this path should be
    /// deleted once legacy codes can no longer be in circulation.
    ///
    /// Not marked `@available(deprecated)` only because the single remaining
    /// call site is the import UI, which must keep compiling warning-free.
    public func decodeLegacyPayload(_ encoded: String) throws -> ConfigTransferPayload {
        guard let data = Data(base64Encoded: encoded), !data.isEmpty else {
            throw ConfigTransferError.invalidFormat
        }
        do {
            return try decoder.decode(ConfigTransferPayload.self, from: deobfuscate(data: data))
        } catch {
            throw ConfigTransferError.decodingFailed
        }
    }

    /// Validates that a payload is recent (within 10 minutes) to prevent replay.
    ///
    /// Used for legacy payloads, whose timestamp is unauthenticated; encrypted
    /// payloads are checked against the envelope's authenticated `createdAt`
    /// inside `decodePayload`.
    public func validatePayloadFreshness(
        _ payload: ConfigTransferPayload,
        maxAge: TimeInterval = ConfigTransferManager.defaultMaxAge
    ) -> Bool {
        abs(payload.timestamp.timeIntervalSinceNow) < maxAge
    }

    // MARK: - Crypto helpers

    /// Derives the AES-GCM key from the typed code. PBKDF2 with a high iteration
    /// count is what makes a short code viable: brute-forcing 40 bits of code
    /// against a captured QR costs ~210k HMACs per guess.
    private func deriveKey(code: String, salt: Data) -> SymmetricKey {
        let derived = KeyDerivation.pbkdf2SHA256(
            password: Data(code.utf8),
            salt: salt + Self.keyDerivationInfo,
            iterations: pbkdf2Iterations,
            keyByteCount: Self.keyByteCount
        )
        return SymmetricKey(data: derived)
    }

    /// Binds the cleartext envelope header into the AES-GCM tag, so downgrading
    /// the version or back-dating `createdAt` to dodge the expiry check
    /// invalidates the ciphertext.
    private static func authenticatedData(version: Int, createdAt: Date, salt: Data) -> Data {
        let header = [
            "justspeaktoit.config-transfer",
            String(version),
            String(Int(createdAt.timeIntervalSince1970)),
            salt.base64EncodedString()
        ].joined(separator: "|")
        return Data(header.utf8)
    }

    /// Minimal decode used to read an envelope's version before trusting the
    /// rest of its fields.
    private struct EnvelopeVersionProbe: Codable {
        let version: Int
    }

    // MARK: - Legacy obfuscation (deprecated)
    // Reversible by anyone with the source; retained only so legacy QR codes
    // remain importable. Never used for new exports.

    private let obfuscationKey: [UInt8] = [0x53, 0x70, 0x65, 0x61, 0x6B, 0x21] // "Speak!"

    private func deobfuscate(data: Data) -> Data {
        var result = Data(count: data.count)
        for (index, byte) in data.enumerated() {
            result[index] = byte ^ obfuscationKey[index % obfuscationKey.count]
        }
        return result
    }
}

/// Which QR format a scanned string uses.
public enum ConfigTransferFormat: Equatable, Sendable {
    /// The current AES-GCM envelope; needs the one-time code from the exporting device.
    case encrypted
    /// The pre-encryption XOR format; deprecated and import-only.
    case legacy
}

public enum ConfigTransferError: LocalizedError, Equatable {
    case invalidFormat
    case payloadExpired
    case decodingFailed
    case invalidCode
    case authenticationFailed
    case unsupportedVersion(Int)
    case encryptionFailed
    case randomGenerationFailed
    case qrGenerationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid QR code format. Please scan a valid Speak configuration code."
        case .payloadExpired:
            return "This configuration code has expired. Please generate a new one."
        case .decodingFailed:
            return "Failed to decode configuration. The code may be corrupted."
        case .invalidCode:
            return "Enter the \(ConfigTransferCode.length)-character code shown on the other device."
        case .authenticationFailed:
            return "That code didn't unlock the configuration. Check the code on the other device and try again."
        case .unsupportedVersion(let version):
            return "This code was made by a newer version of Just Speak to It (format \(version)). "
                + "Update this device, then try again."
        case .encryptionFailed:
            return "Failed to encrypt the configuration for transfer."
        case .randomGenerationFailed:
            return "Failed to generate a secure transfer code. Please try again."
        case .qrGenerationFailed:
            return "Failed to draw the QR code for this configuration."
        }
    }
}

// MARK: - Sync Availability

/// The cross-device sync backend selected by runtime auto-detection.
public enum SyncBackend: String, CaseIterable, Sendable {
    /// iCloud settings/history sync is available and preferred.
    case iCloud
    /// Bonjour local-network transport is available as the fallback path.
    case transport
    /// No cross-device backend is currently available; data remains local.
    case localOnly

    public var displayName: String {
        switch self {
        case .iCloud:
            return "iCloud"
        case .transport:
            return "Bonjour Transport"
        case .localOnly:
            return "Local Only"
        }
    }
}

/// Runtime cross-device sync capability summary for UI and app logic.
public struct SyncAvailability: Equatable, Sendable {
    public let iCloudKVStoreAvailable: Bool
    public let iCloudCloudKitAvailable: Bool
    public let transportAvailable: Bool
    public let distributionChannel: DistributionChannel

    public init(
        iCloudKVStoreAvailable: Bool = false,
        iCloudCloudKitAvailable: Bool = false,
        transportAvailable: Bool = false,
        distributionChannel: DistributionChannel = .current
    ) {
        self.iCloudKVStoreAvailable = iCloudKVStoreAvailable
        self.iCloudCloudKitAvailable = iCloudCloudKitAvailable
        self.transportAvailable = transportAvailable
        self.distributionChannel = distributionChannel
    }

    /// Whether any iCloud sync backend is currently usable.
    public var iCloudAvailable: Bool {
        iCloudKVStoreAvailable || iCloudCloudKitAvailable
    }

    /// Prefer iCloud when any iCloud sync path is available, otherwise fall back
    /// to the canonical Bonjour transport helper, then local-only storage.
    public var preferredBackend: SyncBackend {
        if iCloudAvailable {
            return .iCloud
        }
        if transportAvailable {
            return .transport
        }
        return .localOnly
    }

    /// Checks the build/runtime support for the Bonjour transport fallback.
    public static var currentTransportAvailable: Bool {
        DistributionChannel.current.supportsLocalNetworkTransport
            && !SpeakTransportServiceType.isEmpty
            && SpeakTransportProtocolVersion > 0
    }

    /// Checks current sync availability. CloudKit account availability is owned
    /// by SpeakSync, so callers pass the latest `HistorySyncEngine` state.
    public static func current(iCloudCloudKitAvailable: Bool = false) -> SyncAvailability {
        let sync = SettingsSync.shared

        return SyncAvailability(
            iCloudKVStoreAvailable: sync.isAvailable,
            iCloudCloudKitAvailable: iCloudCloudKitAvailable,
            transportAvailable: currentTransportAvailable,
            distributionChannel: .current
        )
    }
}

// MARK: - Sync Status

/// Represents the current sync status across platforms.
public struct SyncStatus: Equatable, Sendable {
    public let iCloudKeychainAvailable: Bool
    public let iCloudKVStoreAvailable: Bool
    public let iCloudCloudKitAvailable: Bool
    public let transportAvailable: Bool
    public let lastSyncDate: Date?
    public let pendingChanges: Bool
    public let availability: SyncAvailability

    public var preferredBackend: SyncBackend {
        availability.preferredBackend
    }
    
    public init(
        iCloudKeychainAvailable: Bool = false,
        iCloudKVStoreAvailable: Bool = false,
        iCloudCloudKitAvailable: Bool = false,
        transportAvailable: Bool = SyncAvailability.currentTransportAvailable,
        lastSyncDate: Date? = nil,
        pendingChanges: Bool = false
    ) {
        self.iCloudKeychainAvailable = iCloudKeychainAvailable
        self.iCloudKVStoreAvailable = iCloudKVStoreAvailable
        self.iCloudCloudKitAvailable = iCloudCloudKitAvailable
        self.transportAvailable = transportAvailable
        self.lastSyncDate = lastSyncDate
        self.pendingChanges = pendingChanges
        self.availability = SyncAvailability(
            iCloudKVStoreAvailable: iCloudKVStoreAvailable,
            iCloudCloudKitAvailable: iCloudCloudKitAvailable,
            transportAvailable: transportAvailable
        )
    }
    
    /// Checks current sync availability
    public static func current(iCloudCloudKitAvailable: Bool = false) -> SyncStatus {
        let sync = SettingsSync.shared
        let availability = SyncAvailability.current(iCloudCloudKitAvailable: iCloudCloudKitAvailable)
        
        return SyncStatus(
            iCloudKeychainAvailable: KeychainSyncAvailability.isAvailable(),
            iCloudKVStoreAvailable: availability.iCloudKVStoreAvailable,
            iCloudCloudKitAvailable: availability.iCloudCloudKitAvailable,
            transportAvailable: availability.transportAvailable,
            lastSyncDate: sync.lastSyncDate,
            pendingChanges: false
        )
    }
}
