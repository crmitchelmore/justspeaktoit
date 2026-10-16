import Foundation

/// Device-local execution metadata, not a transferred model reference. Settings
/// and History retain the canonical Mac identity; the immutable digest owns files.
public struct HuggingFaceGGUFModel: Codable, Equatable, Sendable, Identifiable {
    public let repository: String
    public let filename: String
    public let revision: String
    public let byteCount: Int64
    public let sha256: String
    public let license: String

    public var model: LocalPostProcessingModel {
        ModelCatalog.localPostProcessing.first { $0.repoID == repository && $0.filename == filename }
            ?? .importedModel(
                repoID: repository, filename: filename,
                approximateSizeMB: Int((byteCount + 1_048_575) / 1_048_576)
            )
    }
    public var id: String { model.id }
    public var storageIdentifier: String { "local/llamacpp/sha256/" + sha256 }
    public var artifact: LocalModelFileArtifact {
        .init(
            url: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")!,
            filename: filename, byteCount: byteCount, sha256: sha256, license: license,
            provenance: "Hugging Face \(repository) @ \(revision), LFS SHA-256 \(sha256)"
        )
    }

    public init(
        repository: String, filename: String, revision: String, byteCount: Int64, sha256: String, license: String
    ) throws {
        try Self.validateInput(repository: repository, filename: filename)
        guard HuggingFaceWhisperModel.isHex(revision, count: 40),
              HuggingFaceWhisperModel.isHex(sha256, count: 64),
              (24...Int64(16 * 1_024 * 1_024 * 1_024)).contains(byteCount),
              !license.isEmpty, license.utf8.count <= 128, license.allSatisfy(\.isASCII),
              !license.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HuggingFaceWhisperError.invalidMetadata
        }
        self.repository = repository
        self.filename = filename
        self.revision = revision
        self.byteCount = byteCount
        self.sha256 = sha256
        self.license = license
    }

    public static func validateInput(repository: String, filename: String) throws {
        // Reuse the established repository grammar without relaxing Whisper's format guard.
        try HuggingFaceWhisperModel.validateInput(repository: repository, filename: "ggml-tiny.bin")
        guard (6...128).contains(filename.utf8.count), !filename.hasPrefix("."),
              filename.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }),
              !filename.contains(".."), filename.lowercased().hasSuffix(".gguf"),
              filename.lowercased().range(of: #"-[0-9]+-of-[0-9]+\.gguf$"#, options: .regularExpression) == nil else {
            throw LocalLLMError.unsupportedArtifact
        }
    }

    private enum CodingKeys: String, CodingKey { case repository, filename, revision, byteCount, sha256, license }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            repository: fields.decode(String.self, forKey: .repository),
            filename: fields.decode(String.self, forKey: .filename),
            revision: fields.decode(String.self, forKey: .revision),
            byteCount: fields.decode(Int64.self, forKey: .byteCount),
            sha256: fields.decode(String.self, forKey: .sha256),
            license: fields.decode(String.self, forKey: .license)
        )
    }
}

public enum LocalLLMError: LocalizedError, Equatable, Sendable {
    case unsupportedArtifact
    case metadataRequired
    case runtimeUnavailable(String)
    case busy
    case closed
    case invalidOutput
    case inference(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedArtifact: return "Choose one unsplit GGUF language-model file, not a path or multipart model."
        case .metadataRequired:
            return "Resolve this GGUF model's immutable Hugging Face metadata on this device before downloading or using it."
        case .runtimeUnavailable(let detail): return "The native local cleanup runtime is unavailable. \(detail)"
        case .busy: return "This local cleanup model is in use, downloading or being removed. Try again when it finishes."
        case .closed: return "Local cleanup is closing; no new work can start."
        case .invalidOutput: return "The local model did not return a complete, non-empty cleanup response."
        case .inference(let detail): return "Local cleanup failed: \(detail)"
        }
    }
}
