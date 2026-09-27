import Foundation

/// A `ModelCatalog.localPostProcessing` entry pinned to exact GGUF bytes for a
/// host that verifies downloads.
///
/// This is not a second model list. Every entry names an existing catalogue
/// identifier (the one saved in settings, profiles and History) and adds only
/// what a verifying host needs: an immutable revision, byte count and SHA-256.
/// The catalogue keeps the display name, repository, file and description.
public struct LlamaCppModel: Hashable, Sendable {
    /// The shared `ModelCatalog.localPostProcessing` identifier, or an
    /// imported model's `local/post-processing/huggingface/...` identifier.
    public let catalogueID: String
    public let displayName: String
    public let summary: String
    public let artifact: LocalModelFileArtifact

    public init(catalogueID: String, displayName: String, summary: String, artifact: LocalModelFileArtifact) {
        self.catalogueID = catalogueID
        self.displayName = displayName
        self.summary = summary
        self.artifact = artifact
    }

    public var backend: LocalModelBackend { .llamaCppGGUF }
}

/// Pinned GGUF files for the shared local cleanup catalogue.
///
/// Qualification rule: an entry is pinned only when its catalogue repository
/// and filename resolve to one file at an immutable Hugging Face revision,
/// recorded here with the byte count and SHA-256 Hugging Face publishes for
/// it (and the downloaded bytes must match both). macOS downloads the same
/// files from `main` through its own runtime and does not need these pins.
public enum LlamaCppModels {
    /// In `ModelCatalog.localPostProcessing` order.
    public static let all: [LlamaCppModel] = pins.compactMap { pin in
        guard let entry = ModelCatalog.localPostProcessing.first(where: { $0.id == pin.catalogueID }) else {
            return nil
        }
        return model(entry: entry, revision: pin.revision, bytes: pin.bytes, sha256: pin.sha256)
    }

    public static func model(forCatalogueID identifier: String) -> LlamaCppModel? {
        let lowered = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.catalogueID == lowered }
    }

    /// The pinned artefact for a GGUF file at an immutable revision.
    public static func model(
        entry: LocalPostProcessingModel, revision: String, bytes: Int64, sha256: String, license: String = "Apache-2.0"
    ) -> LlamaCppModel? {
        guard LocalPostProcessingModel.isGGUFFilename(entry.filename),
              let url = HuggingFaceModelFiles.resolveURL(repoID: entry.repoID, revision: revision, path: entry.filename)
        else { return nil }
        return LlamaCppModel(
            catalogueID: entry.id, displayName: entry.displayName, summary: entry.description,
            artifact: LocalModelFileArtifact(
                url: url, filename: HuggingFaceModelFiles.installedFilename(entry.filename), byteCount: bytes,
                sha256: sha256, license: license,
                provenance: "\(entry.filename) from huggingface.co/\(entry.repoID) at revision \(revision)"
            )
        )
    }

    private struct Pin {
        let catalogueID: String
        let revision: String
        let bytes: Int64
        let sha256: String
    }

    // Revisions, sizes and digests from the Hugging Face API
    // (`/api/models/<repo>/tree/<revision>`, LFS oid and size), 27 Sep 2026.
    private static let pins: [Pin] = [
        Pin(catalogueID: "local/post-processing/qwen3-1.7b-q4", revision: "d7f544eead698dbd1f15126ef60b45a1e1933222",
            bytes: 1_107_409_472, sha256: "b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897"),
        Pin(catalogueID: "local/post-processing/qwen3-0.6b-q4", revision: "50968a4468ef4233ed78cd7c3de230dd1d61a56b",
            bytes: 396_705_472, sha256: "ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a"),
        Pin(catalogueID: "local/post-processing/smollm2-360m-instruct-q4",
            revision: "7be6f65f1db715fe5dc5a4634c0d459b4eed42ec",
            bytes: 270_590_880, sha256: "2fa3f013dcdd7b99f9b237717fa0b12d75bbb89984cc1274be1471a465bac9c2")
    ]
}
