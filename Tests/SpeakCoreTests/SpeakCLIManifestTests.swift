import CryptoKit
import Foundation
import XCTest

@testable import SpeakCore

/// The CLI manifest is trusted only when its detached Ed25519 signature
/// verifies against the Sparkle public key (issue #775).
final class SpeakCLIManifestTests: XCTestCase {
    private let signingKey = Curve25519.Signing.PrivateKey()
    private var publicKeyBase64: String { signingKey.publicKey.rawRepresentation.base64EncodedString() }

    private func makeManifest(version: String = "2.62.0", schema: Int = SpeakCLIManifest.currentSchemaVersion)
        -> SpeakCLIManifest {
        SpeakCLIManifest(
            schemaVersion: schema,
            version: version,
            automationSchemaVersion: AutomationSchema.currentVersion,
            assets: [
                .init(
                    architecture: "arm64",
                    url: URL(string: "https://example.com/speak-\(version)-arm64.zip")!,
                    byteCount: 1234,
                    sha256: String(repeating: "a", count: 64)
                ),
                .init(
                    architecture: "x86_64",
                    url: URL(string: "https://example.com/speak-\(version)-x86_64.zip")!,
                    byteCount: 2345,
                    sha256: String(repeating: "b", count: 64)
                )
            ]
        )
    }

    private func sign(_ data: Data) throws -> String {
        try signingKey.signature(for: data).base64EncodedString()
    }

    func testVerifiedManifest_acceptsAValidSignature() throws {
        let manifest = makeManifest()
        let data = try JSONEncoder().encode(manifest)

        let verified = try SpeakCLIManifestVerifier.verifiedManifest(
            manifestData: data, signatureBase64: try sign(data), publicKeyBase64: publicKeyBase64
        )

        XCTAssertEqual(verified, manifest)
        XCTAssertEqual(verified.asset(for: "ARM64")?.byteCount, 1234, "Architecture lookup is case-insensitive")
        XCTAssertNil(verified.asset(for: "riscv"))
    }

    func testVerifiedManifest_rejectsTamperedBytes() throws {
        let data = try JSONEncoder().encode(makeManifest())
        let signature = try sign(data)
        var tampered = try JSONEncoder().encode(makeManifest(version: "9.9.9"))
        tampered.append(contentsOf: [0x20])

        XCTAssertThrowsError(
            try SpeakCLIManifestVerifier.verifiedManifest(
                manifestData: tampered, signatureBase64: signature, publicKeyBase64: publicKeyBase64
            )
        ) { error in
            XCTAssertEqual(error as? SpeakCLIManifestError, .signatureMismatch)
        }
    }

    func testVerifiedManifest_rejectsAnotherKeyAndMalformedInputs() throws {
        let data = try JSONEncoder().encode(makeManifest())
        let signature = try sign(data)
        let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()

        XCTAssertThrowsError(
            try SpeakCLIManifestVerifier.verifiedManifest(
                manifestData: data, signatureBase64: signature, publicKeyBase64: otherKey
            )
        ) { XCTAssertEqual($0 as? SpeakCLIManifestError, .signatureMismatch) }
        XCTAssertThrowsError(
            try SpeakCLIManifestVerifier.verifiedManifest(
                manifestData: data, signatureBase64: signature, publicKeyBase64: nil
            )
        ) { XCTAssertEqual($0 as? SpeakCLIManifestError, .invalidPublicKey) }
        XCTAssertThrowsError(
            try SpeakCLIManifestVerifier.verifiedManifest(
                manifestData: data, signatureBase64: "not base64!", publicKeyBase64: publicKeyBase64
            )
        ) { XCTAssertEqual($0 as? SpeakCLIManifestError, .invalidSignature) }
    }

    func testVerifiedManifest_rejectsFutureSchemaEvenWhenSigned() throws {
        let data = try JSONEncoder().encode(makeManifest(schema: 2))

        XCTAssertThrowsError(
            try SpeakCLIManifestVerifier.verifiedManifest(
                manifestData: data, signatureBase64: try sign(data), publicKeyBase64: publicKeyBase64
            )
        ) { XCTAssertEqual($0 as? SpeakCLIManifestError, .unsupportedSchema(2)) }
    }

    func testVerifiedManifest_reportsMalformedJSONAfterSignatureCheck() throws {
        let data = Data("{not json".utf8)

        XCTAssertThrowsError(
            try SpeakCLIManifestVerifier.verifiedManifest(
                manifestData: data, signatureBase64: try sign(data), publicKeyBase64: publicKeyBase64
            )
        ) { error in
            guard case .malformed? = error as? SpeakCLIManifestError else {
                return XCTFail("Expected malformed, got \(error)")
            }
        }
    }

    func testArchiveName_andAssetNames_areStable() {
        XCTAssertEqual(SpeakCLIManifest.archiveName(version: "2.62.0", architecture: "arm64"), "speak-2.62.0-arm64.zip")
        XCTAssertEqual(SpeakCLIManifest.manifestAssetName, "speak-cli-manifest.json")
        XCTAssertEqual(SpeakCLIManifest.signatureAssetName, "speak-cli-manifest.json.sig")
    }

    func testStandaloneCLIInstaller_isDirectChannelOnly() {
        XCTAssertTrue(DistributionChannel.direct.supportsStandaloneCLIInstaller)
        XCTAssertFalse(DistributionChannel.appStore.supportsStandaloneCLIInstaller)
    }
}
