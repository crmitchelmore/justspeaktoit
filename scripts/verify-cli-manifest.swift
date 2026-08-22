#!/usr/bin/env swift
// Verify a speak CLI release manifest the way SpeakCLIManifestVerifier in the
// app does (issue #775): the detached Ed25519 signature must check out against
// the Sparkle public key, and every asset must describe the local archive it
// names — architecture, byte count and SHA-256 — for this exact release.
//
// Usage: swift scripts/verify-cli-manifest.swift <manifest.json> <manifest.json.sig|-> \
//            <public-key-base64|-> <version> <automation-schema-version> <zip>...
//
// Pass "-" for the signature and key to check an unsigned development manifest
// structurally only; a release manifest must always be checked signed.

import CryptoKit
import Foundation

struct Asset: Decodable {
    let architecture: String
    let url: URL
    let byteCount: Int
    let sha256: String
}

struct Manifest: Decodable {
    let schemaVersion: Int
    let version: String
    let automationSchemaVersion: Int
    let assets: [Asset]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 6 else {
    fail("usage: verify-cli-manifest.swift <manifest> <sig|-> <public-key|-> <version> <schema-version> <zip>...")
}
let manifestPath = arguments[0]
let signaturePath = arguments[1]
let publicKeyBase64 = arguments[2]
let expectedVersion = arguments[3]
guard let expectedSchema = Int(arguments[4]) else { fail("automation schema version must be a number") }
let archives = arguments[5...].map { URL(fileURLWithPath: $0) }

guard let manifestData = FileManager.default.contents(atPath: manifestPath) else {
    fail("cannot read \(manifestPath)")
}

// Signature first: nothing in an unverified manifest is trusted.
if signaturePath != "-" || publicKeyBase64 != "-" {
    guard signaturePath != "-", publicKeyBase64 != "-" else {
        fail("both the signature and the public key are required to verify a signed manifest")
    }
    guard let signatureText = FileManager.default.contents(atPath: signaturePath)
        .flatMap({ String(data: $0, encoding: .utf8) })
    else { fail("cannot read \(signaturePath)") }
    guard let keyBytes = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
    else { fail("the public key is not a base64 Ed25519 key") }
    guard let signature = Data(base64Encoded: signatureText.trimmingCharacters(in: .whitespacesAndNewlines)),
          signature.count == 64
    else { fail("the signature file does not hold a base64 Ed25519 signature") }
    guard publicKey.isValidSignature(signature, for: manifestData) else {
        fail("the manifest signature does not verify with the supplied public key")
    }
    print("==> signature verifies with the Sparkle public key")
} else {
    print("==> unsigned manifest: structural checks only")
}

let manifest: Manifest
do {
    manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
} catch {
    fail("the manifest does not decode: \(error)")
}
guard manifest.schemaVersion == 1 else { fail("schemaVersion is \(manifest.schemaVersion), expected 1") }
guard manifest.version == expectedVersion else {
    fail("manifest version is \(manifest.version), expected \(expectedVersion)")
}
guard manifest.automationSchemaVersion == expectedSchema else {
    fail("automationSchemaVersion is \(manifest.automationSchemaVersion), expected \(expectedSchema)")
}

let releasePrefix = "https://github.com/crmitchelmore/justspeaktoit/releases/download/mac-v\(expectedVersion)/"
var remaining = Dictionary(uniqueKeysWithValues: archives.map { ($0.lastPathComponent, $0) })
var seenArchitectures: Set<String> = []
for asset in manifest.assets {
    guard ["arm64", "x86_64"].contains(asset.architecture) else {
        fail("unsupported architecture \(asset.architecture)")
    }
    guard seenArchitectures.insert(asset.architecture).inserted else {
        fail("\(asset.architecture) is listed more than once")
    }
    let name = asset.url.lastPathComponent
    guard name == "speak-\(expectedVersion)-\(asset.architecture).zip" else {
        fail("\(asset.architecture) asset is named \(name)")
    }
    guard asset.url.absoluteString == releasePrefix + name else {
        fail("\(name) must be published at \(releasePrefix)\(name), not \(asset.url.absoluteString)")
    }
    guard let archive = remaining.removeValue(forKey: name) else {
        fail("\(name) was not supplied for verification")
    }
    guard let data = FileManager.default.contents(atPath: archive.path) else {
        fail("cannot read \(archive.path)")
    }
    guard data.count == asset.byteCount else {
        fail("\(name) is \(data.count) bytes, manifest says \(asset.byteCount)")
    }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard digest == asset.sha256.lowercased() else {
        fail("\(name) SHA-256 is \(digest), manifest says \(asset.sha256)")
    }
    print("==> \(name): \(asset.byteCount) bytes, sha256 \(digest)")
}
guard remaining.isEmpty else {
    fail("archives without a manifest entry: \(remaining.keys.sorted().joined(separator: ", "))")
}
guard !manifest.assets.isEmpty else { fail("the manifest lists no assets") }
print("==> manifest verified for speak \(manifest.version) (automation protocol v\(manifest.automationSchemaVersion))")
