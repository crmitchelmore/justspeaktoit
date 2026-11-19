import Foundation

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
    /// Backward-compatible default envelope version. v0 is the legacy XOR
    /// format, which has no envelope and is only accepted on import.
    public static let currentVersion = 1
    /// Oversized transfers compress the plaintext before authenticated encryption.
    public static let compressedVersion = 2

    static func supports(version: Int) -> Bool {
        version == currentVersion || version == compressedVersion
    }

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
/// (`I`/`l` → `1`, `O` → `0`). Eight characters give 40 bits of entropy, and
/// PBKDF2 stretching slows a brute-force attempt, but neither prevents offline
/// decryption once both factors have been captured. The source UI therefore
/// shows the code only after the QR has left the screen
/// (see `ConfigTransferPresentation`).
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
    case compressionFailed
    case payloadTooLarge
    case randomGenerationFailed
    case qrGenerationFailed
    case unknownSecretIdentifier(String)
    case unknownSettingKey(String)
    case emptySecretValue(String)
    case emptySettingValue(String)
    case rollbackFailed(identifiers: [String])

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
        case .compressionFailed:
            return "Failed to compress the configuration for transfer. Please try again."
        case .payloadTooLarge:
            return "This configuration is too large for one QR code. "
                + "Use iCloud key sync or enter the API keys on the other device."
        case .randomGenerationFailed:
            return "Failed to generate a secure transfer code. Please try again."
        case .qrGenerationFailed:
            return "Failed to draw the QR code for this configuration."
        case .unknownSecretIdentifier:
            return "This configuration contains a credential this version does not recognise. "
                + "Update both devices, then try again."
        case .unknownSettingKey:
            return "This configuration contains a setting this version does not recognise. "
                + "Update both devices, then try again."
        case .emptySecretValue, .emptySettingValue:
            return "This configuration contains an empty value and was not applied. "
                + "Generate a new code on the other device, then try again."
        case .rollbackFailed:
            return "The import failed and some credentials could not be restored. "
                + "Review your API keys in Settings before dictating."
        }
    }
}
