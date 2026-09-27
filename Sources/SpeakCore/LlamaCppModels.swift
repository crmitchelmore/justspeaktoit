import Foundation

/// A GGUF language model a host that verifies downloads may run through
/// llama.cpp: a `ModelCatalog.localPostProcessing` entry pinned to exact
/// bytes, or a GGUF file the user imported from Hugging Face and pinned to
/// the revision, size and SHA-256 Hugging Face reported at import.
///
/// This is not a second model list. Catalogue entries keep their identifier,
/// display name and description; this adds only the verified artefact.
public struct LlamaCppModel: Hashable, Sendable {
    /// The `local/post-processing/...` identifier saved in settings and History.
    public let identifier: String
    public let displayName: String
    public let summary: String
    public let artifact: LocalModelFileArtifact

    public init(identifier: String, displayName: String, summary: String, artifact: LocalModelFileArtifact) {
        self.identifier = identifier
        self.displayName = displayName
        self.summary = summary
        self.artifact = artifact
    }

    public var backend: LocalModelBackend { .llamaCppGGUF }
}

/// Pinned GGUF files for the catalogue's local post-processing models.
///
/// Qualification rule: an entry is listed only when its catalogue repository
/// and filename are pinned here to an immutable Hugging Face revision, byte
/// count and SHA-256 (read from the Hugging Face API's LFS metadata for that
/// revision and checked again by every download). The Windows CI job runs the
/// smallest entry through the bundled llama.cpp runtime on a CPU-only runner;
/// the others share its architecture family and chat template handling.
public enum LlamaCppModels {
    static let provenanceSuffix = "converted to GGUF"

    /// In `ModelCatalog.localPostProcessing` order.
    public static let all: [LlamaCppModel] = [
        pinned(
            "local/post-processing/qwen3-1.7b-q4", revision: "d7f544eead698dbd1f15126ef60b45a1e1933222",
            bytes: 1_107_409_472, sha256: "b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897",
            license: "Apache-2.0", base: "Qwen/Qwen3-1.7B"
        ),
        pinned(
            "local/post-processing/qwen3-0.6b-q4", revision: "50968a4468ef4233ed78cd7c3de230dd1d61a56b",
            bytes: 396_705_472, sha256: "ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a",
            license: "Apache-2.0", base: "Qwen/Qwen3-0.6B"
        ),
        pinned(
            "local/post-processing/smollm2-360m-instruct-q4", revision: "7be6f65f1db715fe5dc5a4634c0d459b4eed42ec",
            bytes: 270_590_880, sha256: "2fa3f013dcdd7b99f9b237717fa0b12d75bbb89984cc1274be1471a465bac9c2",
            license: "Apache-2.0", base: "HuggingFaceTB/SmolLM2-360M-Instruct"
        )
    ].compactMap { $0 }

    public static func model(for identifier: String) -> LlamaCppModel? {
        let lowered = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.identifier == lowered }
    }

    /// A Hugging Face `resolve` URL pinned to one revision. Each path
    /// component is percent-encoded; the result is nil for an invalid name.
    public static func huggingFaceURL(repoID: String, revision: String, filename: String) -> URL? {
        let encode = { (value: Substring) in
            value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/", "?", "#"]))
        }
        let parts = repoID.split(separator: "/") + [Substring(revision)] + filename.split(separator: "/")
        let encoded = parts.compactMap(encode)
        guard encoded.count == parts.count, repoID.split(separator: "/").count == 2 else { return nil }
        let path = encoded[0] + "/" + encoded[1] + "/resolve/" + encoded[2...].joined(separator: "/")
        return URL(string: "https://huggingface.co/" + path)
    }

    private static func pinned(
        _ identifier: String, revision: String, bytes: Int64, sha256: String, license: String, base: String
    ) -> LlamaCppModel? {
        guard let entry = ModelCatalog.localPostProcessing.first(where: { $0.id == identifier }),
              let url = huggingFaceURL(repoID: entry.repoID, revision: revision, filename: entry.filename) else {
            return nil
        }
        return LlamaCppModel(
            identifier: entry.id, displayName: entry.displayName, summary: entry.description,
            artifact: LocalModelFileArtifact(
                url: url, filename: entry.filename, byteCount: bytes, sha256: sha256, license: license,
                provenance: "\(base) weights \(provenanceSuffix) (huggingface.co/\(entry.repoID) at revision \(revision))"
            )
        )
    }
}
