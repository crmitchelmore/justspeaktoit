import Foundation

/// A `ModelCatalog.localPostProcessing` entry that a bundled llama.cpp is
/// qualified to serve, with its GGUF weights pinned by exact bytes.
///
/// This is not a second model list. Every entry names an existing catalogue
/// identifier (the one saved in settings, profiles and History) and adds only
/// what a host that downloads by pin needs: the immutable Hugging Face
/// revision, byte count, SHA-256 and licence of the catalogue's file.
public struct LlamaCppModel: Hashable, Sendable {
    /// The shared `ModelCatalog.localPostProcessing` identifier.
    public let catalogueID: String
    public let displayName: String
    public let summary: String
    public let repository: String
    public let revision: String
    public let artifact: LocalModelFileArtifact

    public var backend: LocalModelBackend { .llamaCppGGUF }

    /// The desktop hosts' digest identity for the same weights
    /// (`HuggingFaceGGUFModel.storageIdentifier`).
    public var storageIdentifier: String { "local/llamacpp/sha256/" + artifact.sha256 }
}

/// Pinned GGUF weights for the recommended local cleanup models.
///
/// Qualification rule: an entry is listed only for a `localPostProcessing`
/// model, using that entry's repository and filename at a pinned revision,
/// with the file's Hugging Face LFS byte count and SHA-256. Desktop hosts
/// resolve the same files through `HuggingFaceGGUFModel` metadata at run time;
/// Android cannot, so it downloads exactly these pins
/// (`LlamaCppAndroidExport`). Changing a pin means a new revision, size and
/// digest together, and fresh device checks.
public enum LlamaCppModels {
    /// In `ModelCatalog.localPostProcessing` order.
    public static let all: [LlamaCppModel] = [
        Pin(catalogueID: "local/post-processing/qwen3-1.7b-q4",
            revision: "d7f544eead698dbd1f15126ef60b45a1e1933222", bytes: 1_107_409_472,
            sha256: "b139949c5bd74937ad8ed8c8cf3d9ffb1e99c866c823204dc42c0d91fa181897"),
        Pin(catalogueID: "local/post-processing/qwen3-0.6b-q4",
            revision: "50968a4468ef4233ed78cd7c3de230dd1d61a56b", bytes: 396_705_472,
            sha256: "ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a"),
        Pin(catalogueID: "local/post-processing/smollm2-360m-instruct-q4",
            revision: "7be6f65f1db715fe5dc5a4634c0d459b4eed42ec", bytes: 270_590_880,
            sha256: "2fa3f013dcdd7b99f9b237717fa0b12d75bbb89984cc1274be1471a465bac9c2")
    ].compactMap(model)

    public static func model(forCatalogueID identifier: String) -> LlamaCppModel? {
        let lowered = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.catalogueID == lowered }
    }

    /// All three recommended models are Apache-2.0 (Qwen3 and SmolLM2 model cards).
    static let license = "Apache-2.0"

    struct Pin {
        let catalogueID: String
        let revision: String
        let bytes: Int64
        let sha256: String
    }

    /// Nil only when the pin names no catalogue entry, which the parity tests reject.
    static func model(_ pin: Pin) -> LlamaCppModel? {
        guard let entry = ModelCatalog.localPostProcessing.first(where: { $0.id == pin.catalogueID }),
              let url = URL(string: "https://huggingface.co/\(entry.repoID)/resolve/\(pin.revision)/\(entry.filename)")
        else {
            return nil
        }
        return LlamaCppModel(
            catalogueID: entry.id, displayName: entry.displayName, summary: entry.description,
            repository: entry.repoID, revision: pin.revision,
            artifact: LocalModelFileArtifact(
                url: url, filename: entry.filename, byteCount: pin.bytes, sha256: pin.sha256, license: license,
                provenance: "Hugging Face \(entry.repoID) @ \(pin.revision), LFS SHA-256 \(pin.sha256)"
            )
        )
    }
}
