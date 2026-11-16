import Foundation

/// The whisper.cpp pins as JSON for the Android app, so its Downloaded models
/// list, download URLs and integrity checks come from `WhisperCppModels`
/// rather than a copied list.
///
/// Android capability rule: Android offers every pinned model, except that a
/// model with `minimumDeviceMemoryBytes` is offered only on a phone whose
/// `ActivityManager.MemoryInfo.totalMem` is at least that. The rule lives here,
/// beside the shared pins, not in an Android-owned list.
///
/// `WhisperCppAndroidExportTests` fails when the committed asset is stale;
/// regenerate it with `scripts/update-android-assets`.
public enum WhisperCppAndroidExport {
    /// Large v3 Turbo needs about 1 GB while it transcribes (550 MB of weights
    /// plus whisper.cpp's buffers). A phone sold with 6 GB reports roughly
    /// 5.5 GiB of `totalMem`, and one sold with 4 GB about 3.6 GiB, so 5 GiB
    /// admits 6 GB phones and leaves 4 GB ones on the smaller models. The owner's
    /// device measurements (#1658) may move this.
    static let largeModelMinimumDeviceMemoryBytes: Int64 = 5 * 1_024 * 1_024 * 1_024

    /// Catalogue identifiers Android offers only above a device memory floor.
    static let memoryFloors: [String: Int64] = [
        "local/whisperkit/large-v3-turbo": largeModelMinimumDeviceMemoryBytes
    ]

    public static func minimumDeviceMemoryBytes(forCatalogueID identifier: String) -> Int64? {
        memoryFloors[identifier]
    }

    public static func json() throws -> Data {
        struct Model: Encodable {
            let catalogId, displayName, summary, quantization: String
            let multilingual: Bool
            let url, filename: String
            let bytes: Int64
            let sha256, license, provenance: String
            let allowedHosts: [String]
            let minimumDeviceMemoryBytes: Int64?
        }
        struct Document: Encodable {
            let version: Int
            let repository, revision: String
            let models: [Model]
        }
        let document = Document(
            version: 1,
            repository: WhisperCppModels.repository,
            revision: WhisperCppModels.revision,
            models: WhisperCppModels.all.map { model in
                Model(
                    catalogId: model.catalogueID, displayName: model.displayName, summary: model.summary,
                    quantization: model.quantization, multilingual: model.multilingual,
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
