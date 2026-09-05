import Foundation
import XCTest
@testable import SpeakCore

final class ConfigTransferQRCapacityTests: XCTestCase {
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
}
