import Foundation
import SpeakCore
import SpeakDesktop

enum WhisperImportFixtures {
    static let revision = String(repeating: "a", count: 40)
    static let digest = String(repeating: "b", count: 64)

    static func header(type: UInt32 = 1) -> Data {
        let values: [UInt32] = [0x6767_6D6C, 51_865, 1_500, 384, 6, 4, 448, 384, 6, 4, 80, type]
        return values.reduce(into: Data()) { data, word in
            var little = word.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
    }

    static func model(body: Data? = nil) throws -> HuggingFaceWhisperModel {
        let bytes = body ?? header()
        return try HuggingFaceWhisperModel(
            repository: "fixture/whisper", filename: "ggml-tiny.bin", revision: revision,
            byteCount: Int64(bytes.count), sha256: TestSHA256.hex(bytes), license: "MIT"
        )
    }

    static func metadata(
        revision: String = WhisperImportFixtures.revision, digest: String = WhisperImportFixtures.digest, size: Int64 = 48,
        filename: String = "ggml-tiny.bin", duplicate: Bool = false, hasLFS: Bool = true
    ) throws -> Data {
        var file: [String: Any] = ["rfilename": filename, "size": size]
        if hasLFS { file["lfs"] = ["sha256": digest, "size": size] }
        return try JSONSerialization.data(withJSONObject: [
            "id": "fixture/whisper", "sha": revision, "cardData": ["license": "MIT"],
            "siblings": duplicate ? [file, file] : [file]
        ])
    }
}

final class FixtureWhisperMetadata: HuggingFaceModelMetadataTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Data]
    private var requests: [URL] = []
    let delay: Bool

    init(_ bodies: [Data], delay: Bool = false) { self.bodies = bodies; self.delay = delay }
    var urls: [URL] { lock.withLock { requests } }

    func metadata(at url: URL) async throws -> Data {
        let data = try lock.withLock { () throws -> Data in
            requests.append(url)
            guard !bodies.isEmpty else { throw HuggingFaceWhisperError.invalidMetadata }
            return bodies.removeFirst()
        }
        if delay { try await Task.sleep(for: .seconds(60)) }
        try Task.checkCancellation()
        return data
    }
}
