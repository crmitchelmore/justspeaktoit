import Foundation

/// The pinned llama.cpp cleanup models as JSON for the Android app, so its
/// downloaded cleanup list, download URLs and integrity checks come from
/// `ModelCatalog.localPostProcessing` and `LlamaCppModels` rather than a
/// copied list.
///
/// Android capability rule: Android offers every pinned model, except that a
/// model with `minimumDeviceMemoryBytes` is offered only on a phone whose
/// `ActivityManager.MemoryInfo.totalMem` is at least that. The rule lives here,
/// beside the shared pins, not in an Android-owned list.
/// iOS applies the same floor to `ProcessInfo.physicalMemory`
/// (`IOSLocalCleanupModels.offered`).
///
/// `LlamaCppAndroidExportTests` fails when the committed asset is stale;
/// regenerate it with `scripts/update-android-assets`.
public enum LlamaCppAndroidExport {
    /// Qwen3 1.7B Q4 needs about 1.4 GB while it runs (1.1 GB of weights plus
    /// the KV cache for a long transcript). As for Whisper Large v3 Turbo, 5 GiB
    /// of `totalMem` admits phones sold with 6 GB and leaves 4 GB phones on the
    /// smaller models. The owner's device measurements (#1660) may move this.
    static let largeModelMinimumDeviceMemoryBytes: Int64 = 5 * 1_024 * 1_024 * 1_024

    /// Catalogue identifiers Android offers only above a device memory floor.
    static let memoryFloors: [String: Int64] = [
        "local/post-processing/qwen3-1.7b-q4": largeModelMinimumDeviceMemoryBytes
    ]

    public static func minimumDeviceMemoryBytes(forCatalogueID identifier: String) -> Int64? {
        memoryFloors[identifier]
    }

    public static func json() throws -> Data {
        struct Model: Encodable {
            let catalogId, displayName, summary, repository, revision: String
            let url, filename: String
            let bytes: Int64
            let sha256, license, provenance: String
            let allowedHosts: [String]
            let minimumDeviceMemoryBytes: Int64?
        }
        struct Document: Encodable {
            let version: Int
            let models: [Model]
        }
        let document = Document(
            version: 1,
            models: LlamaCppModels.all.map { model in
                Model(
                    catalogId: model.catalogueID, displayName: model.displayName, summary: model.summary,
                    repository: model.repository, revision: model.revision,
                    url: model.artifact.url.absoluteString, filename: model.artifact.filename,
                    bytes: model.artifact.byteCount, sha256: model.artifact.sha256,
                    license: model.artifact.license, provenance: model.artifact.provenance,
                    allowedHosts: model.artifact.allowedHosts.sorted(),
                    minimumDeviceMemoryBytes: minimumDeviceMemoryBytes(forCatalogueID: model.catalogueID)
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(document)
        data.append(0x0A)
        return data
    }
}
