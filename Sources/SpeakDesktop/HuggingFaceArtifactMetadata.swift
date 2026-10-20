import Foundation
import SpeakCore

/// One bounded reader for both GGML and GGUF. Format admission stays with each
/// model type; resolving a file never establishes runtime compatibility.
struct HuggingFaceArtifactMetadata: Equatable, Sendable {
    let repository: String
    let filename: String
    let revision: String
    let byteCount: Int64
    let sha256: String
    let license: String

    static func discover(
        repository: String, filename: String, transport: any HuggingFaceModelMetadataTransport,
        validate: @Sendable (Self) throws -> Void
    ) async throws -> Self {
        try Task.checkCancellation()
        let first = try await read(repository: repository, filename: filename, revision: "main", transport: transport)
        try validate(first)
        try Task.checkCancellation()
        let pinned = try await read(
            repository: repository, filename: filename, revision: first.revision, transport: transport
        )
        guard first == pinned else { throw HuggingFaceWhisperError.revisionChanged }
        try validate(pinned)
        try Task.checkCancellation()
        return pinned
    }

    private static func read(
        repository: String, filename: String, revision: String, transport: any HuggingFaceModelMetadataTransport
    ) async throws -> Self {
        let url = URL(string: "https://huggingface.co/api/models/\(repository)/revision/\(revision)?blobs=true")!
        let data = try await transport.metadata(at: url)
        try Task.checkCancellation()
        guard data.count <= HuggingFaceWhisperDiscovery.maximumMetadataBytes else {
            throw HuggingFaceWhisperError.invalidMetadata
        }
        let response = try JSONDecoder().decode(Repository.self, from: data)
        guard response.id == repository, response.siblings.count <= 4_096,
              revision == "main" || response.sha == revision else { throw HuggingFaceWhisperError.revisionChanged }
        let matches = response.siblings.filter { $0.rfilename == filename }
        guard matches.count == 1, let file = matches.first, let lfs = file.lfs,
              file.size == nil || file.size == lfs.size,
              HuggingFaceWhisperModel.isHex(response.sha, count: 40),
              HuggingFaceWhisperModel.isHex(lfs.sha256, count: 64), lfs.size >= 24 else {
            throw HuggingFaceWhisperError.invalidMetadata
        }
        let license = response.cardData?.license ?? "Not declared; check the repository"
        guard !license.isEmpty, license.utf8.count <= 128, license.allSatisfy(\.isASCII),
              !license.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw HuggingFaceWhisperError.invalidMetadata
        }
        return .init(
            repository: repository, filename: filename, revision: response.sha,
            byteCount: lfs.size, sha256: lfs.sha256, license: license
        )
    }

    private struct Repository: Decodable {
        let id: String
        let sha: String
        let siblings: [File]
        let cardData: Card?
    }
    private struct Card: Decodable { let license: String? }
    private struct File: Decodable { let rfilename: String; let size: Int64?; let lfs: LFS? }
    private struct LFS: Decodable { let sha256: String; let size: Int64 }
}

public struct HuggingFaceGGUFDiscovery: Sendable {
    public let transport: any HuggingFaceModelMetadataTransport
    public init(transport: any HuggingFaceModelMetadataTransport = HuggingFaceModelMetadataHTTP()) {
        self.transport = transport
    }

    public func discover(repository: String, filename: String) async throws -> HuggingFaceGGUFModel {
        try HuggingFaceGGUFModel.validateInput(repository: repository, filename: filename)
        let file = try await HuggingFaceArtifactMetadata.discover(
            repository: repository, filename: filename, transport: transport
        ) {
            _ = try HuggingFaceGGUFModel(
                repository: repository, filename: filename, revision: $0.revision,
                byteCount: $0.byteCount, sha256: $0.sha256, license: $0.license
            )
        }
        return try .init(
            repository: repository, filename: filename, revision: file.revision,
            byteCount: file.byteCount, sha256: file.sha256, license: file.license
        )
    }
}
