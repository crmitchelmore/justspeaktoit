import CryptoKit
import Foundation
import zlib

extension ConfigTransferManager {
    /// Accepts the original base64-wrapped envelope and the raw-envelope JSON
    /// used when a full credential set would not fit a QR code (issue #699).
    static func envelopeCandidateData(from encoded: String) -> Data? {
        if let data = Data(base64Encoded: encoded), !data.isEmpty {
            return data
        }
        if encoded.hasPrefix("{") {
            return Data(encoded.utf8)
        }
        return nil
    }

    static func sealEnvelope(
        _ plaintext: Data,
        version: Int,
        createdAt: Date,
        salt: Data,
        key: SymmetricKey
    ) throws -> ConfigTransferEnvelope {
        let nonce = AES.GCM.Nonce()
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(
                plaintext,
                using: key,
                nonce: nonce,
                authenticating: authenticatedData(version: version, createdAt: createdAt, salt: salt)
            )
        } catch {
            throw ConfigTransferError.encryptionFailed
        }
        return ConfigTransferEnvelope(
            version: version,
            createdAt: createdAt,
            salt: salt,
            nonce: Data(nonce),
            ciphertext: sealedBox.ciphertext + sealedBox.tag
        )
    }

    /// A fixed output buffer bounds decompression before any payload is decoded.
    static func decompressPayload(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumPlaintextBytes else {
            throw ConfigTransferError.decodingFailed
        }
        var stream = z_stream()
        // Apple's .zlib compression produces raw DEFLATE. Native zlib reports
        // exact stream consumption, unlike Compression's buffered read-ahead.
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ConfigTransferError.decodingFailed
        }
        defer { inflateEnd(&stream) }
        var output = Data(count: maximumPlaintextBytes + 1)
        let count = output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int? in
            data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int? in
                guard let sourcePointer = source.bindMemory(to: UInt8.self).baseAddress,
                      let destinationPointer = destination.bindMemory(to: UInt8.self).baseAddress else { return nil }
                stream.next_in = UnsafeMutablePointer(mutating: sourcePointer)
                stream.avail_in = uInt(source.count)
                stream.next_out = destinationPointer
                stream.avail_out = uInt(destination.count)
                guard inflate(&stream, Z_FINISH) == Z_STREAM_END,
                      stream.avail_in == 0, stream.total_out <= maximumPlaintextBytes else {
                    return nil
                }
                return Int(stream.total_out)
            }
        }
        guard let count, count > 0 else { throw ConfigTransferError.decodingFailed }
        output.count = count
        return output
    }
}
