import Foundation
import XCTest
import SpeakSync
@testable import SpeakDesktopSync

/// The shared Windows/Linux envelope adapter over a synthetic C function table.
final class DesktopNativeEnvelopeCryptographyTests: XCTestCase {
    func testNativeStatusesMapToEnvelopeFailuresAndBuffersRoundTrip() throws {
        let crypto = DesktopNativeEnvelopeCryptography(
            pbkdf2: { _, _, _, _, iterations, key, count, _, _ in
                for index in 0..<count { key?[index] = UInt8(truncatingIfNeeded: iterations) }
                return 0
            },
            seal: { _, _, plaintext, count, nonce, ciphertext, tag, _, _ in
                for index in 0..<12 { nonce?[index] = 1 }
                for index in 0..<16 { tag?[index] = 2 }
                for index in 0..<count { ciphertext?[index] = (plaintext?[index] ?? 0) ^ 0xFF }
                return 0
            },
            open: { _, _, _, ciphertext, count, tag, plaintext, _, _ in
                guard tag?[0] == 2 else { return -1 }
                for index in 0..<count { plaintext?[index] = (ciphertext?[index] ?? 0) ^ 0xFF }
                return 0
            },
            random: { _, _, _, _ in -1 }
        )
        XCTAssertEqual(try crypto.pbkdf2SHA256(password: Data([1]), salt: Data([2]), iterations: 7, keyByteCount: 2),
                       Data([7, 7]))
        XCTAssertThrowsError(try crypto.pbkdf2SHA256(password: Data(), salt: Data(), iterations: 0, keyByteCount: 2))
        let sealed = try crypto.sealAESGCM(Data([0x10, 0x20]), key: Data(repeating: 0, count: 32))
        XCTAssertEqual(sealed.nonce, Data(repeating: 1, count: 12))
        XCTAssertEqual(try crypto.openAESGCM(sealed, key: Data(repeating: 0, count: 32)), Data([0x10, 0x20]))
        let forged = SealedEnvelopePayload(nonce: sealed.nonce, ciphertext: sealed.ciphertext,
                                           tag: Data(repeating: 9, count: 16))
        XCTAssertThrowsError(try crypto.openAESGCM(forged, key: Data(repeating: 0, count: 32)))
        XCTAssertThrowsError(try crypto.randomBytes(count: 4))
    }
}
