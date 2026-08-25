import CryptoKit
import Foundation

/// Describes the standalone `speak` CLI assets published alongside a macOS
/// release, so the app can install and update the CLI independently of the
/// app bundle (issue #775).
///
/// The manifest is published as a release asset next to a detached Ed25519
/// signature made with the same key that signs Sparkle updates, so the app
/// verifies it with the `SUPublicEDKey` it already ships. Only a manifest that
/// verifies is trusted for the per-asset byte counts and SHA-256 digests.
public struct SpeakCLIManifest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    /// Release asset names; the manifest and its signature sit next to the CLI archives.
    public static let manifestAssetName = "speak-cli-manifest.json"
    public static let signatureAssetName = "speak-cli-manifest.json.sig"

    public struct Asset: Codable, Equatable, Sendable {
        /// `arm64` or `x86_64`, matching `uname -m` on the target Mac.
        public let architecture: String
        public let url: URL
        public let byteCount: Int
        /// Lowercase hex SHA-256 of the archive at `url`.
        public let sha256: String

        public init(architecture: String, url: URL, byteCount: Int, sha256: String) {
            self.architecture = architecture
            self.url = url
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    public let schemaVersion: Int
    /// Marketing version of the CLI, identical to the app release it shipped with.
    public let version: String
    /// `AutomationSchema.currentVersion` the CLI was built against.
    public let automationSchemaVersion: Int
    public let assets: [Asset]

    public init(
        schemaVersion: Int = SpeakCLIManifest.currentSchemaVersion,
        version: String,
        automationSchemaVersion: Int,
        assets: [Asset]
    ) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.automationSchemaVersion = automationSchemaVersion
        self.assets = assets
    }

    public func asset(for architecture: String) -> Asset? {
        assets.first { $0.architecture.caseInsensitiveCompare(architecture) == .orderedSame }
    }

    /// Asset names as the release workflow publishes them.
    public static func archiveName(version: String, architecture: String) -> String {
        "speak-\(version)-\(architecture).zip"
    }
}

public enum SpeakCLIManifestError: LocalizedError, Equatable {
    case invalidPublicKey
    case invalidSignature
    case signatureMismatch
    case unsupportedSchema(Int)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPublicKey:
            return "The app's update signing key is missing or malformed, so the CLI manifest cannot be verified."
        case .invalidSignature:
            return "The CLI manifest signature is malformed."
        case .signatureMismatch:
            return "The CLI manifest signature does not match. The download was not trusted."
        case .unsupportedSchema(let version):
            return "The CLI manifest uses format \(version), which this app does not understand. Update the app."
        case .malformed(let detail):
            return "The CLI manifest could not be read: \(detail)"
        }
    }
}

public enum SpeakCLIManifestVerifier {
    /// Verifies `signatureBase64` (an Ed25519 signature over the exact manifest
    /// bytes, as produced by Sparkle's `sign_update`) against the Sparkle
    /// public key, then decodes the manifest. Nothing in the manifest is used
    /// before the signature checks out.
    public static func verifiedManifest(
        manifestData: Data,
        signatureBase64: String,
        publicKeyBase64: String?
    ) throws -> SpeakCLIManifest {
        guard let publicKeyBase64,
              let keyBytes = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
        else { throw SpeakCLIManifestError.invalidPublicKey }
        guard let signature = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              signature.count == 64
        else { throw SpeakCLIManifestError.invalidSignature }
        guard publicKey.isValidSignature(signature, for: manifestData) else {
            throw SpeakCLIManifestError.signatureMismatch
        }
        let manifest: SpeakCLIManifest
        do {
            manifest = try JSONDecoder().decode(SpeakCLIManifest.self, from: manifestData)
        } catch {
            throw SpeakCLIManifestError.malformed(error.localizedDescription)
        }
        guard manifest.schemaVersion == SpeakCLIManifest.currentSchemaVersion else {
            throw SpeakCLIManifestError.unsupportedSchema(manifest.schemaVersion)
        }
        return manifest
    }
}
