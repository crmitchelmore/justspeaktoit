import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation

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
    private var envelopeDecoder: JSONDecoder { Self.makeCoderDecoder() }

    static func encodeEnvelope(_ envelope: ConfigTransferEnvelope) throws -> Data {
        let encoder = Self.makeCoderEncoder()
        // Base64 ciphertext contains random slashes. Escaping them adds a
        // random number of bytes and can push a valid transfer over QR capacity.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

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
    ///

    /// Non-secret settings keys a transfer payload may carry. Import refuses
    /// anything else so a payload cannot write arbitrary defaults.
    ///
    /// `transcriptionKeywords` is the one keyword list both platforms store
    /// under that defaults key, so it transfers verbatim.
    public static let transferableSettingKeys: Set<String> = [
        "selectedModel",
        transcriptionKeywordsKey
    ]

    /// Shared UserDefaults key for the user's transcription keywords.
    public static let transcriptionKeywordsKey = "transcriptionKeywords"

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
        // Import refuses empty values, and an empty keyword list carries
        // nothing worth transferring anyway.
        if let keywords = defaults.string(forKey: Self.transcriptionKeywordsKey), !keywords.isEmpty {
            settings[Self.transcriptionKeywordsKey] = keywords
        }
        return settings
    }

    /// Builds the QR code image for an encoded payload, scaled up for crisp
    /// on-screen display. Callers wrap the `CIImage` in the platform image
    /// type (NSImage/UIImage).
    public func makeQRCodeImage(payload: String, scale: CGFloat = 10) -> CIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        // Level M for the compatible payload size; a full credential set only
        // fits at level L (2,953 bytes), which remains reliable for the short
        // screen-to-camera scan this feature performs (issue #699).
        filter.correctionLevel = payload.utf8.count > 2_200 ? "L" : "M"
        guard let outputImage = filter.outputImage else { return nil }
        return outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    // MARK: - Export

    /// Builds an encrypted QR payload together with the one-time code that
    /// unlocks it. The exporting device reveals the code after removing the QR; it is
    /// never encoded into the QR, so scanning the image alone reveals nothing.
    public func makeTransfer(
        secrets: [String: String],
        settings: [String: String]
    ) throws -> ConfigTransfer {
        let code = try ConfigTransferCode.generate()
        let payload = try generatePayload(secrets: secrets, settings: settings, code: code)
        return ConfigTransfer(payload: payload, code: code)
    }

    /// Encrypts a payload under `code` and returns a QR-compatible envelope string.
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
        guard plaintext.count <= Self.maximumPlaintextBytes else {
            throw ConfigTransferError.payloadTooLarge
        }

        guard let salt = KeyDerivation.randomBytes(count: Self.saltByteCount) else {
            throw ConfigTransferError.randomGenerationFailed
        }
        let timestamp = Date(timeIntervalSince1970: (createdAt.timeIntervalSince1970).rounded(.down))
        let key = deriveKey(code: normalizedCode, salt: salt)
        let envelope = try Self.sealEnvelope(
            plaintext,
            version: ConfigTransferEnvelope.currentVersion,
            createdAt: timestamp,
            salt: salt,
            key: key
        )
        var encoded = try Self.encodeEnvelope(envelope)
        if encoded.count > Self.maximumQRCodePayloadBytes {
            let compressed: Data
            do {
                compressed = try (plaintext as NSData).compressed(using: .zlib) as Data
            } catch {
                throw ConfigTransferError.compressionFailed
            }
            let compactEnvelope = try Self.sealEnvelope(
                compressed,
                version: ConfigTransferEnvelope.compressedVersion,
                createdAt: timestamp,
                salt: salt,
                key: key
            )
            encoded = try Self.encodeEnvelope(compactEnvelope)
            guard encoded.count <= Self.maximumQRCodePayloadBytes else {
                throw ConfigTransferError.payloadTooLarge
            }
            guard let json = String(bytes: encoded, encoding: .utf8) else {
                throw ConfigTransferError.encryptionFailed
            }
            return json
        }
        let base64 = encoded.base64EncodedString()
        // Keep v1 and its older base64 wrapper whenever they fit.
        if base64.utf8.count > Self.maximumCompatiblePayloadLength {
            guard let json = String(bytes: encoded, encoding: .utf8) else {
                throw ConfigTransferError.encryptionFailed
            }
            return json
        }
        return base64
    }

    /// QR byte capacity at correction level M. Above this the doubly-encoded
    /// payload cannot be drawn, so export falls back to the raw envelope JSON.
    static let maximumCompatiblePayloadLength = 2_331
    static let maximumQRCodePayloadBytes = 2_953
    static let maximumPlaintextBytes = 64 * 1_024

    // MARK: - Import

    /// Inspects a scanned string without decrypting it, so the importing UI
    /// knows whether to ask for a one-time code. Unknown envelope versions are
    /// rejected here rather than being mistaken for a legacy payload.
    public func format(of encoded: String) throws -> ConfigTransferFormat {
        guard let data = Self.envelopeCandidateData(from: encoded) else {
            throw ConfigTransferError.invalidFormat
        }

        if let probe = try? envelopeDecoder.decode(EnvelopeVersionProbe.self, from: data) {
            guard ConfigTransferEnvelope.supports(version: probe.version) else {
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

        let payloadData = envelope.version == ConfigTransferEnvelope.compressedVersion
            ? try Self.decompressPayload(plaintext) : plaintext
        do {
            return try decoder.decode(ConfigTransferPayload.self, from: payloadData)
        } catch {
            throw ConfigTransferError.decodingFailed
        }
    }

    /// Parses (but does not decrypt) the envelope, rejecting unknown versions.
    public func decodeEnvelope(_ encoded: String) throws -> ConfigTransferEnvelope {
        guard let data = Self.envelopeCandidateData(from: encoded) else {
            throw ConfigTransferError.invalidFormat
        }
        guard let envelope = try? envelopeDecoder.decode(ConfigTransferEnvelope.self, from: data) else {
            throw ConfigTransferError.decodingFailed
        }
        guard ConfigTransferEnvelope.supports(version: envelope.version) else {
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
    static func authenticatedData(version: Int, createdAt: Date, salt: Data) -> Data {
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
