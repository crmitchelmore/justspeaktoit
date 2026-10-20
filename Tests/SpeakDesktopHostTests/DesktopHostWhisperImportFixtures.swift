import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost

struct RefusedWhisperMetadata: HuggingFaceModelMetadataTransport {
    func metadata(at url: URL) async throws -> Data { throw HuggingFaceWhisperError.invalidMetadata }
}

enum HostWhisperImportFixture {
    static let digest = String(repeating: "d", count: 64)
    static let revision = String(repeating: "e", count: 40)
    static var body: Data {
        let words: [UInt32] = [0x6767_6D6C, 51_865, 1_500, 384, 6, 4, 448, 384, 6, 4, 80, 1]
        return words.reduce(into: Data()) { data, word in
            var little = word.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
    }
    static var model: HuggingFaceWhisperModel {
        get throws {
            try HuggingFaceWhisperModel(
                repository: "fixture/whisper", filename: "ggml-tiny.bin", revision: revision,
                byteCount: Int64(body.count), sha256: digest, license: "MIT"
            )
        }
    }
    static func metadata() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": "fixture/whisper", "sha": revision, "cardData": ["license": "MIT"],
            "siblings": [["rfilename": "ggml-tiny.bin", "size": body.count,
                          "lfs": ["size": body.count, "sha256": digest]]]
        ])
    }
}

final class HostWhisperMetadata: HuggingFaceModelMetadataTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    let held: Bool
    let invalid: Bool
    init(held: Bool = false, invalid: Bool = false) { self.held = held; self.invalid = invalid }
    var count: Int { lock.withLock { requests } }

    func metadata(at url: URL) async throws -> Data {
        lock.withLock { requests += 1 }
        if held { try await Task.sleep(for: .seconds(60)) }
        try Task.checkCancellation()
        if invalid { return Data("not metadata".utf8) }
        return try HostWhisperImportFixture.metadata()
    }
}

final class HostWhisperDownload: LocalModelDownloadTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    private let held: Bool
    private let failure: Bool
    init(held: Bool = false, failure: Bool = false) { self.held = held; self.failure = failure }
    var count: Int { lock.withLock { requests } }
    func download(
        _ request: LocalModelDownloadRequest, start: @escaping @Sendable (LocalModelDownloadStart) throws -> Void,
        sink: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        lock.withLock { requests += 1 }
        try start(.fromBeginning)
        if held { try await Task.sleep(for: .seconds(60)) }
        try Task.checkCancellation()
        if failure { throw CocoaError(.fileReadUnknown) }
        try sink(HostWhisperImportFixture.body)
    }
}

extension DesktopHostController where Platform == FakeLocalPlatform {
    var localImportInProgressForTests: Bool { localModels.importTask != nil }
    var localImportModelsForTests: [HuggingFaceWhisperModel] { localModels.imported }
    var activeLocalOperationsForTests: Int { activeOperations }
}
