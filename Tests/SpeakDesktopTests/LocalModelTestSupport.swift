import Foundation
import SpeakCore
@testable import SpeakDesktop

/// A plain FIPS 180-4 SHA-256 for tests only. Production digests come from the
/// platform (CNG on Windows, CryptoKit on Apple); the portable Linux test host
/// has neither, and the installer tests need real digests of their fixtures.
final class TestSHA256: LocalModelSHA256Hasher {
    private static let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]
    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0
    private var finished = false

    static var provider: LocalModelDigestProvider {
        LocalModelDigestProvider(name: "test SHA-256") { TestSHA256() }
    }

    static func hex(_ data: Data) -> String {
        let hasher = TestSHA256()
        data.withUnsafeBytes { try? hasher.update($0) }
        return (try? hasher.finish()) ?? ""
    }

    func update(_ bytes: UnsafeRawBufferPointer) throws {
        guard !finished else { throw LocalModelDigestError.reused }
        length += UInt64(bytes.count)
        buffer.append(contentsOf: bytes)
        var offset = 0
        while buffer.count - offset >= 64 {
            compress(buffer[offset..<(offset + 64)])
            offset += 64
        }
        buffer.removeFirst(offset)
    }

    func finish() throws -> String {
        guard !finished else { throw LocalModelDigestError.reused }
        finished = true
        var tail = buffer + [0x80]
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = length &* 8
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
        }
        for start in stride(from: 0, to: tail.count, by: 64) { compress(tail[start..<(start + 64)]) }
        return state.map { String(format: "%08x", $0) }.joined()
    }

    private func compress(_ block: ArraySlice<UInt8>) {
        var words = [UInt32](repeating: 0, count: 64)
        let base = block.startIndex
        for index in 0..<16 {
            words[index] = (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(block[base + index * 4 + $1]) }
        }
        func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 { value >> amount | value << (32 - amount) }
        for index in 16..<64 {
            let sigma0 = rotate(words[index - 15], 7) ^ rotate(words[index - 15], 18) ^ (words[index - 15] >> 3)
            let sigma1 = rotate(words[index - 2], 17) ^ rotate(words[index - 2], 19) ^ (words[index - 2] >> 10)
            words[index] = words[index - 16] &+ sigma0 &+ words[index - 7] &+ sigma1
        }
        // Working variables a...h of FIPS 180-4, section 6.2.2.
        var work = state
        for index in 0..<64 {
            let upper1 = rotate(work[4], 6) ^ rotate(work[4], 11) ^ rotate(work[4], 25)
            let choice = (work[4] & work[5]) ^ (~work[4] & work[6])
            let temp1 = work[7] &+ upper1 &+ choice &+ Self.constants[index] &+ words[index]
            let upper0 = rotate(work[0], 2) ^ rotate(work[0], 13) ^ rotate(work[0], 22)
            let majority = (work[0] & work[1]) ^ (work[0] & work[2]) ^ (work[1] & work[2])
            let temp2 = upper0 &+ majority
            work = [temp1 &+ temp2, work[0], work[1], work[2], work[3] &+ temp1, work[4], work[5], work[6]]
        }
        for index in 0..<8 { state[index] = state[index] &+ work[index] }
    }
}

/// Serves one body with optional range support and injected failures.
final class FakeModelTransport: LocalModelDownloadTransport, @unchecked Sendable {
    enum Failure { case none, dropAfter(Int), cancelAfter(Int) }
    private struct Settings {
        let failure: Failure
        let honoursRange: Bool
        let chunkSize: Int
    }

    private let lock = NSLock()
    let body: Data
    var honoursRange = true
    var failure: Failure = .none
    var chunkSize = 7
    private(set) var requests: [LocalModelDownloadRequest] = []

    init(body: Data) { self.body = body }

    func download(
        _ request: LocalModelDownloadRequest,
        start: @escaping @Sendable (LocalModelDownloadStart) throws -> Void,
        sink: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        let settings = lock.withLock { () -> Settings in
            requests.append(request)
            return Settings(failure: failure, honoursRange: honoursRange, chunkSize: chunkSize)
        }
        let offset = settings.honoursRange ? Int(request.resumeOffset) : 0
        try start(offset > 0 ? .resumed(offset: Int64(offset)) : .fromBeginning)
        var position = offset
        var sent = 0
        while position < body.count {
            let end = min(position + settings.chunkSize, body.count)
            switch settings.failure {
            case .dropAfter(let limit) where sent >= limit:
                throw LocalModelDownloadError.transport("connection reset")
            case .cancelAfter(let limit) where sent >= limit:
                throw CancellationError()
            default: break
            }
            try sink(body.subdata(in: position..<end))
            sent += end - position
            position = end
        }
    }
}

extension LocalModelInstaller.Item {
    static func fixture(_ body: Data, digest: String? = nil, identifier: String = "local/whisperkit/tiny") -> Self {
        LocalModelInstaller.Item(
            identifier: identifier, displayName: "Fixture model",
            artifact: LocalModelFileArtifact(
                url: URL(string: "https://huggingface.co/example/models/resolve/0000/ggml-fixture.bin")!,
                filename: "ggml-fixture.bin", byteCount: Int64(body.count),
                sha256: digest ?? TestSHA256.hex(body), license: "MIT", provenance: "test fixture"
            )
        )
    }
}

enum LocalModelTestFiles {
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsti-local-model-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A canonical 16 kHz mono PCM16 WAV, optionally with a LIST chunk.
    static func wav(samples: [Int16], listChunk: Bool = false) -> Data {
        var pcm = Data()
        for sample in samples { withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) } }
        func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
        func le16(_ value: Int) -> [UInt8] { (0..<2).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
        var chunks = Data("fmt ".utf8)
        chunks.append(contentsOf: le32(16))
        for field in [le16(1), le16(1), le32(16_000), le32(32_000), le16(2), le16(16)] {
            chunks.append(contentsOf: field)
        }
        if listChunk {
            chunks.append(Data("LIST".utf8))
            chunks.append(contentsOf: le32(4))
            chunks.append(Data("INFO".utf8))
        }
        chunks.append(Data("data".utf8))
        chunks.append(contentsOf: le32(pcm.count))
        chunks.append(pcm)
        var file = Data("RIFF".utf8)
        file.append(contentsOf: le32(4 + chunks.count))
        file.append(Data("WAVE".utf8))
        file.append(chunks)
        return file
    }
}
