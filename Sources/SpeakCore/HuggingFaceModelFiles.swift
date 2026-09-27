import Foundation

/// Hugging Face repository listings for hosts that import single-file local
/// models (whisper.cpp GGML and llama.cpp GGUF) and verify them.
///
/// Discovery reads `/api/models/<repo>` for the current immutable revision
/// and licence, then `/api/models/<repo>/tree/<revision>?recursive=true` for
/// each file's size and the SHA-256 Hugging Face stores as its LFS object id.
/// An import pins the file to that revision, byte count and digest, so the
/// downloaded bytes are verified exactly as a catalogue model's are.
public enum HuggingFaceModelFiles {
    /// What a listed file is to a host.
    public enum Kind: String, Codable, Sendable {
        /// whisper.cpp speech weights (`ggml-*.bin`).
        case whisperGGML = "whisper-ggml"
        /// A single-file llama.cpp language model (`*.gguf`).
        case llamaGGUF = "llama-gguf"
    }

    /// A file a host could import, pinned to the revision it was listed at.
    public struct Candidate: Equatable, Sendable {
        public let repoID: String
        public let revision: String
        public let path: String
        public let byteCount: Int64
        public let sha256: String
        public let kind: Kind
        public let license: String?

        public var filename: String { installedFilename(path) }
    }

    public struct Listing: Equatable, Sendable {
        public let repoID: String
        public let revision: String
        public let license: String?
        public let candidates: [Candidate]
        /// Files skipped because they are not single-file GGML/GGUF models,
        /// for an explanation when nothing is importable.
        public let skippedCount: Int
    }

    public enum ListingError: LocalizedError, Equatable {
        case invalidRepository
        case malformedResponse
        case unsupportedFile(String)

        public var errorDescription: String? {
            switch self {
            case .invalidRepository:
                return "Enter a Hugging Face repository as owner/name, for example ggerganov/whisper.cpp."
            case .malformedResponse:
                return "Hugging Face returned a listing this app could not read."
            case .unsupportedFile(let name):
                return "\(name) is not a single-file whisper.cpp (ggml-*.bin) or llama.cpp (.gguf) model."
            }
        }
    }

    /// Largest file accepted from a listing: 40 GiB.
    public static let maximumBytes: Int64 = 40 * 1_073_741_824

    /// A trimmed `owner/name` repository identifier, or `nil`. Accepts a pasted
    /// `https://huggingface.co/owner/name` URL.
    public static func normalizedRepoID(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://huggingface.co/", "http://huggingface.co/", "huggingface.co/"]
        where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).prefix(2).map(String.init)
        guard parts.count == 2 else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        for part in parts {
            guard (1...96).contains(part.count), part.unicodeScalars.allSatisfy(allowed.contains),
                  part != ".", part != "..", !part.hasPrefix("-") else { return nil }
        }
        return "\(parts[0])/\(parts[1])"
    }

    public static func modelInfoURL(repoID: String) -> URL? {
        URL(string: "https://huggingface.co/api/models/\(repoID)")
    }

    public static func treeURL(repoID: String, revision: String) -> URL? {
        guard isRevision(revision) else { return nil }
        return URL(string: "https://huggingface.co/api/models/\(repoID)/tree/\(revision)?recursive=true")
    }

    /// The browser search a host opens for manual discovery.
    public static func searchURL(for kind: Kind) -> URL {
        switch kind {
        case .whisperGGML:
            // Constant URL.
            return URL(string: "https://huggingface.co/models?search=whisper%20ggml&sort=downloads")!
        case .llamaGGUF:
            return URL(string: "https://huggingface.co/models?library=gguf&pipeline_tag=text-generation&sort=trending")!
        }
    }

    public static func resolveURL(repoID: String, revision: String, path: String) -> URL? {
        guard normalizedRepoID(repoID) == repoID, isRevision(revision), isSafePath(path) else { return nil }
        let encoded = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
                ?? String($0)
        }.joined(separator: "/")
        return URL(string: "https://huggingface.co/\(repoID)/resolve/\(revision)/\(encoded)")
    }

    /// The file's basename, which is how it is stored on disk.
    public static func installedFilename(_ path: String) -> String {
        String(path.split(separator: "/").last ?? Substring(path))
    }

    /// Classifies a repository path, or `nil` when no local runtime can load
    /// it as a single file. Split GGUF shards, multimodal projectors, Core ML
    /// encoders and whisper.cpp's test fixtures are rejected.
    public static func kind(ofPath path: String) -> Kind? {
        guard isSafePath(path) else { return nil }
        let name = installedFilename(path).lowercased()
        if name.hasSuffix(".gguf") {
            if name.contains("mmproj") { return nil }
            if name.range(of: #"-\d{5}-of-\d{5}\.gguf$"#, options: .regularExpression) != nil { return nil }
            return .llamaGGUF
        }
        if name.hasPrefix("ggml-"), name.hasSuffix(".bin"), !name.contains("encoder"), !name.contains("coreml") {
            return .whisperGGML
        }
        return nil
    }

    /// Parses `/api/models/<repo>`: the current commit and the declared licence.
    public static func parseModelInfo(_ data: Data) throws -> (revision: String, license: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let revision = object["sha"] as? String, isRevision(revision) else {
            throw ListingError.malformedResponse
        }
        let card = object["cardData"] as? [String: Any]
        var license = card?["license"] as? String
        if license == nil, let tags = object["tags"] as? [String] {
            license = tags.first { $0.hasPrefix("license:") }.map { String($0.dropFirst("license:".count)) }
        }
        return (revision, license)
    }

    /// Parses a recursive tree listing into importable files, largest last
    /// within each kind so smaller downloads appear first.
    public static func parseTree(
        _ data: Data, repoID: String, revision: String, license: String?
    ) throws -> Listing {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ListingError.malformedResponse
        }
        var candidates: [Candidate] = []
        var skipped = 0
        for entry in entries where (entry["type"] as? String) == "file" {
            guard let path = entry["path"] as? String else { continue }
            guard let kind = kind(ofPath: path),
                  let lfs = entry["lfs"] as? [String: Any],
                  let digest = (lfs["oid"] as? String)?.lowercased(),
                  digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let size = (lfs["size"] as? NSNumber)?.int64Value ?? (entry["size"] as? NSNumber)?.int64Value,
                  size > 0, size <= maximumBytes else {
                skipped += 1
                continue
            }
            candidates.append(Candidate(
                repoID: repoID, revision: revision, path: path, byteCount: size, sha256: digest, kind: kind,
                license: license
            ))
        }
        candidates.sort { ($0.kind.rawValue, $0.byteCount, $0.path) < ($1.kind.rawValue, $1.byteCount, $1.path) }
        return Listing(repoID: repoID, revision: revision, license: license, candidates: candidates,
                       skippedCount: skipped)
    }

    static func isRevision(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
    }

    /// A relative repository path without traversal, backslashes or controls.
    static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count <= 512, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}

/// A single-file model imported from Hugging Face and pinned for verified
/// download. The Codable form is persisted by desktop hosts; keep its field
/// names. The identifier derives from the repository and path, so importing
/// the same file again replaces the earlier pin rather than adding a second
/// entry.
public struct ImportedLocalModelFile: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: HuggingFaceModelFiles.Kind
    public let repoID: String
    public let path: String
    public let revision: String
    public let byteCount: Int64
    public let sha256: String
    public let license: String?

    public init(candidate: HuggingFaceModelFiles.Candidate) {
        switch candidate.kind {
        case .whisperGGML:
            id = LocalModelIdentity.whisperCppHuggingFaceModelID(repoID: candidate.repoID, filename: candidate.path)
        case .llamaGGUF:
            id = LocalPostProcessingModel.huggingFaceModelID(repoID: candidate.repoID, filename: candidate.path)
        }
        kind = candidate.kind
        repoID = candidate.repoID
        path = candidate.path
        revision = candidate.revision
        byteCount = candidate.byteCount
        sha256 = candidate.sha256
        license = candidate.license
    }

    public var filename: String { HuggingFaceModelFiles.installedFilename(path) }

    /// A record whose identity, path or pins were altered is refused on load.
    public var isValid: Bool {
        HuggingFaceModelFiles.kind(ofPath: path) == kind
            && HuggingFaceModelFiles.normalizedRepoID(repoID) == repoID
            && HuggingFaceModelFiles.isRevision(revision)
            && sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
            && byteCount > 0 && byteCount <= HuggingFaceModelFiles.maximumBytes
            && id == ImportedLocalModelFile(candidate: .init(
                repoID: repoID, revision: revision, path: path, byteCount: byteCount, sha256: sha256, kind: kind,
                license: license
            )).id
    }

    /// "ggml-medium.en from ggerganov/whisper.cpp"; the name History shows.
    public var displayName: String {
        switch kind {
        case .whisperGGML:
            let base = filename.replacingOccurrences(of: ".bin", with: "", options: [.caseInsensitive, .backwards])
            return "\(base) from \(repoID)"
        case .llamaGGUF:
            return LocalPostProcessingModel.importedDisplayName(repoID: repoID, filename: filename)
        }
    }

    public var artifact: LocalModelFileArtifact? {
        guard let url = HuggingFaceModelFiles.resolveURL(repoID: repoID, revision: revision, path: path) else {
            return nil
        }
        return LocalModelFileArtifact(
            url: url, filename: filename, byteCount: byteCount, sha256: sha256, license: license ?? "unknown",
            provenance: "\(path) from huggingface.co/\(repoID) at revision \(revision), imported by the user"
        )
    }

    /// The whisper.cpp model for a GGML import. Imported speech models are
    /// batch-only: none has a live-qualification receipt.
    public var whisperCppModel: WhisperCppModel? {
        guard kind == .whisperGGML, let artifact else { return nil }
        let name = filename.lowercased()
        let quantization = name.range(of: #"q[0-9]_[0-9k]"#, options: .regularExpression).map { String(name[$0]) }
            ?? "f16"
        return WhisperCppModel(
            catalogueID: id, displayName: displayName,
            summary: "Imported from huggingface.co/\(repoID). Runs through the bundled whisper.cpp runtime; "
                + "batch only, because imported models are not qualified for live dictation.",
            quantization: quantization, multilingual: !name.contains(".en"), supportsLiveStreaming: false,
            artifact: artifact
        )
    }

    /// The cleanup catalogue entry and pinned artefact for a GGUF import.
    public var llamaCppModel: LlamaCppModel? {
        guard kind == .llamaGGUF, let artifact else { return nil }
        let entry = LocalPostProcessingModel.importedModel(
            repoID: repoID, filename: filename, approximateSizeMB: Int(byteCount / 1_048_576)
        )
        return LlamaCppModel(
            catalogueID: id, displayName: entry.displayName, summary: entry.description, artifact: artifact
        )
    }
}
