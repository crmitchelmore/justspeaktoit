import Foundation

/// A portable whisper.cpp import, not a WhisperKit/Core ML reference. Only
/// standard Whisper GGML checkpoints are admitted; installation also checks
/// the downloaded header, and recognition hashes the bytes it actually loads.
public struct HuggingFaceWhisperModel: Codable, Hashable, Sendable, DownloadedLocalModel, Identifiable {
    public static let identifierPrefix = "local/whispercpp/huggingface/"
    public static let maximumByteCount: Int64 = 8 * 1_024 * 1_024 * 1_024

    public let repository: String
    public let filename: String
    public let revision: String
    public let byteCount: Int64
    public let sha256: String
    public let license: String

    /// Content-addressed, so a new upstream revision cannot replace an
    /// installed selection or resume bytes belonging to different weights.
    public var id: String { Self.identifierPrefix + sha256 }
    public var backend: LocalModelBackend? { .whisperCppGGML }
    public var backends: Set<LocalModelBackend> { [.whisperCppGGML] }
    public var displayName: String {
        "Whisper \(filename.dropFirst(5).dropLast(4)) from \(repository)"
    }
    /// History transferred without this device's metadata cannot recover the
    /// repository name. A digest label is descriptive, never an execution grant.
    public static func fallbackDisplayName(for identifier: String) -> String? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        let digest = String(identifier.dropFirst(identifierPrefix.count))
        guard isHex(digest, count: 64) else { return nil }
        return "Imported Whisper GGML (\(digest.prefix(8)))"
    }
    public var artifact: LocalModelFileArtifact {
        LocalModelFileArtifact(
            url: URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")!,
            filename: filename, byteCount: byteCount, sha256: sha256,
            license: license, provenance: "Hugging Face \(repository) @ \(revision), LFS SHA-256 \(sha256)"
        )
    }
    public var model: WhisperCppModel {
        WhisperCppModel(
            catalogueID: id, displayName: displayName,
            summary: "Imported GGML checkpoint from \(repository), frozen at \(revision). Batch only.",
            quantization: filename.contains("-q") ? String(filename.dropLast(4).suffix(4)) : "GGML",
            multilingual: !filename.contains(".en"), artifact: artifact
        )
    }

    public init(
        repository: String, filename: String, revision: String, byteCount: Int64, sha256: String, license: String
    ) throws {
        try Self.validateInput(repository: repository, filename: filename)
        guard Self.isHex(revision, count: 40), Self.isHex(sha256, count: 64),
              (48...Self.maximumByteCount).contains(byteCount),
              !license.isEmpty, license.utf8.count <= 128,
              license.allSatisfy({ $0.isASCII }),
              !license.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
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
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ part in
            (1...96).contains(part.utf8.count) && part.first.map { $0.isLetter || $0.isNumber } == true
                && !part.contains("..") && !part.hasSuffix(".")
                && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        }) else { throw HuggingFaceWhisperError.invalidRepository }
        let pattern = #"^ggml-(tiny|base|small|medium)(\.en)?(-(q4_[01]|q5_[01]|q8_0))?\.bin\z"#
        let large = #"^ggml-large-(v1|v2|v3(-turbo)?)(-(q4_[01]|q5_[01]|q8_0))?\.bin\z"#
        guard filename.utf8.count <= 96,
              filename.range(of: pattern, options: .regularExpression) != nil
                || filename.range(of: large, options: .regularExpression) != nil else {
            throw HuggingFaceWhisperError.unsupportedArtifact
        }
    }

    public static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private enum CodingKeys: String, CodingKey {
        case repository, filename, revision, byteCount, sha256, license
    }

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

public enum HuggingFaceWhisperError: LocalizedError, Equatable, Sendable {
    case invalidRepository, unsupportedArtifact, invalidMetadata, revisionChanged, incompatibleHeader, importLimit

    public var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "Enter a Hugging Face owner/repository, not a URL or path."
        case .unsupportedArtifact:
            return "Choose a standard ggml-tiny/base/small/medium or ggml-large-v1/v2/v3 .bin checkpoint. "
                + "Core ML, ONNX, GGUF, distilled and renamed/unqualified formats are not supported."
        case .invalidMetadata:
            return "Hugging Face did not supply valid immutable revision, size and LFS SHA-256 metadata."
        case .revisionChanged:
            return "The immutable Hugging Face revision did not match its discovery metadata. Nothing was imported."
        case .incompatibleHeader:
            return "These bytes are not a supported Whisper GGML checkpoint. They were not installed or used."
        case .importLimit:
            return "This device already retains the maximum of 64 distinct imported model references."
        }
    }
}
