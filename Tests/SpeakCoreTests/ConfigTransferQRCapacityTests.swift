import Foundation
import XCTest
@testable import SpeakCore

final class ConfigTransferQRCapacityTests: XCTestCase {
    func testFullProviderSetWithBoundAlibabaCredentialFitsQRCode() throws {
        let identifiers = Set(ConfigTransferManager.transferableSecretIdentifiers).union([
            "alibaba.apiKey", "reson8.apiKey", "smallest.apiKey", "stepfun.apiKey"
        ])
        var secrets = Dictionary(uniqueKeysWithValues: identifiers.sorted().enumerated().map {
            ($1, syntheticKey(seed: $0, length: 90))
        })
        let configuration = try AlibabaSpeechConfiguration(
            region: .singapore, workspace: "llm-12345678901234567890", apiKey: syntheticKey(seed: 100, length: 90)
        )
        secrets["alibaba.apiKey"] = try configuration.encodedCredentials()
        let manager = ConfigTransferManager(pbkdf2Iterations: 1_000)
        let transfer = try manager.makeTransfer(
            secrets: secrets,
            settings: ["selectedModel": "deepgram/nova-3-streaming"]
        )

        XCTAssertLessThanOrEqual(transfer.payload.utf8.count, 2_953)
        XCTAssertNotNil(manager.makeQRCodeImage(payload: transfer.payload))
        let restored = try manager.decodePayload(transfer.payload, code: transfer.code).secrets
        XCTAssertEqual(restored, secrets)
        XCTAssertEqual(
            try AlibabaSpeechConfiguration(credentials: XCTUnwrap(restored["alibaba.apiKey"])),
            configuration
        )
    }

    func testEnvelopeWithWorstCaseBase64SlashesStillFitsQRCode() throws {
        // 2,079 encrypted bytes match the existing full 18-key, 90-character
        // credential fixture. All 0xff makes almost every base64 byte a slash,
        // reproducing the capacity bug deterministically instead of retrying RNG.
        let envelope = ConfigTransferEnvelope(
            version: ConfigTransferEnvelope.currentVersion,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            salt: Data(repeating: 0xff, count: 16),
            nonce: Data(repeating: 0xff, count: 12),
            ciphertext: Data(repeating: 0xff, count: 2_079)
        )
        let data = try ConfigTransferManager.encodeEnvelope(envelope)
        let encoded = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertTrue(encoded.contains("////"))
        XCTAssertFalse(encoded.contains("\\/"))
        XCTAssertLessThanOrEqual(data.count, 2_953)
        XCTAssertNotNil(ConfigTransferManager.shared.makeQRCodeImage(payload: encoded))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ConfigTransferEnvelope.self, from: data), envelope)
    }

    func testCompactEnvelopeVersionIsAuthenticated() throws {
        let manager = ConfigTransferManager(pbkdf2Iterations: 1_000)
        let encoded = try manager.generatePayload(
            secrets: ["deepgram.apiKey": String(repeating: "x", count: 4_000)],
            settings: [:], code: "A1B2C3D4"
        )
        let envelope = try manager.decodeEnvelope(encoded)
        XCTAssertEqual(envelope.version, ConfigTransferEnvelope.compressedVersion)
        XCTAssertEqual(try manager.format(of: encoded), .encrypted)
        XCTAssertNotNil(manager.makeQRCodeImage(payload: encoded))
        let downgraded = ConfigTransferEnvelope(
            version: ConfigTransferEnvelope.currentVersion,
            createdAt: envelope.createdAt, salt: envelope.salt,
            nonce: envelope.nonce, ciphertext: envelope.ciphertext
        )
        let changed = try XCTUnwrap(String(
            bytes: try ConfigTransferManager.encodeEnvelope(downgraded), encoding: .utf8
        ))
        XCTAssertThrowsError(try manager.decodePayload(changed, code: "A1B2C3D4")) {
            XCTAssertEqual($0 as? ConfigTransferError, .authenticationFailed)
        }
        XCTAssertThrowsError(try manager.decodePayload(encoded, code: "Z9Y8X7W6")) {
            XCTAssertEqual($0 as? ConfigTransferError, .authenticationFailed)
        }
    }

    func testBoundedDecompressionAcceptsExactLimitAndRejectsExpansionBeyondIt() throws {
        let data = Data(repeating: 120, count: ConfigTransferManager.maximumPlaintextBytes)
        let compressed = try (data as NSData).compressed(using: .zlib) as Data
        XCTAssertEqual(try ConfigTransferManager.decompressPayload(compressed), data)

        let oversized = data + Data([120])
        let compressedOversized = try (oversized as NSData).compressed(using: .zlib) as Data
        XCTAssertThrowsError(try ConfigTransferManager.decompressPayload(compressedOversized)) {
            XCTAssertEqual($0 as? ConfigTransferError, .decodingFailed)
        }
    }

    func testBoundedDecompressionRejectsCorruptionTruncationAndTrailingData() throws {
        let data = Data(syntheticKey(seed: 500, length: 1_000).utf8)
        let compressed = try (data as NSData).compressed(using: .zlib) as Data
        for (index, invalid) in [
            Data(), Data([0, 1, 2, 3]), Data(compressed.dropLast()),
            compressed + Data([1, 2, 3])
        ].enumerated() {
            XCTAssertThrowsError(try ConfigTransferManager.decompressPayload(invalid), "Invalid fixture \(index)") {
                XCTAssertEqual($0 as? ConfigTransferError, .decodingFailed)
            }
        }
    }

    func testIncompressibleOversizedTransferFailsWithActionableError() {
        let manager = ConfigTransferManager(pbkdf2Iterations: 1_000)
        XCTAssertThrowsError(try manager.makeTransfer(
            secrets: ["deepgram.apiKey": syntheticKey(seed: 10, length: 6_000)],
            settings: [:]
        )) {
            XCTAssertEqual($0 as? ConfigTransferError, .payloadTooLarge)
        }
        XCTAssertThrowsError(try manager.makeTransfer(
            secrets: ["deepgram.apiKey": String(repeating: "x", count: ConfigTransferManager.maximumPlaintextBytes)],
            settings: [:]
        )) {
            XCTAssertEqual($0 as? ConfigTransferError, .payloadTooLarge)
        }
    }

    private func syntheticKey(seed: Int, length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var state = UInt64(seed) &+ 1
        return String((0..<length).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return alphabet[Int(state >> 33) % alphabet.count]
        })
    }
}
