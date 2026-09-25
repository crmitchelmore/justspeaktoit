import Foundation

/// One downloadable model file qualified by its exact bytes. The URL is pinned
/// to an immutable revision; a file with another size or SHA-256 is a
/// different artefact, never a variant of this one.
public struct LocalModelFileArtifact: Hashable, Sendable {
    public let url: URL
    /// The installed file name. A plain basename, never a path.
    public let filename: String
    public let byteCount: Int64
    /// Lowercase hexadecimal SHA-256 of the file contents.
    public let sha256: String
    /// SPDX identifier of the weights' licence.
    public let license: String
    /// Where the weights come from, for notices and History provenance.
    public let provenance: String

    public init(url: URL, filename: String, byteCount: Int64, sha256: String, license: String, provenance: String) {
        self.url = url
        self.filename = filename
        self.byteCount = byteCount
        self.sha256 = sha256
        self.license = license
        self.provenance = provenance
    }

    /// Hosts a download of this artefact may be redirected to. Hugging Face
    /// serves pinned files from its own content hosts; integrity comes from
    /// the size and SHA-256, never from the host.
    public var allowedHosts: Set<String> {
        guard let host = url.host?.lowercased() else { return [] }
        if host == "huggingface.co" { return WhisperCppModels.huggingFaceHosts }
        return [host]
    }
}

/// A catalogue Whisper entry that whisper.cpp is qualified to serve.
///
/// This is not a second model list. Every entry names an existing
/// `ModelCatalog.localTranscription` identifier (the one saved in settings,
/// profiles and History) and adds only what whisper.cpp needs: pinned GGML
/// weights. A catalogue entry without one here is not offered by a
/// whisper.cpp host.
public struct WhisperCppModel: Hashable, Sendable {
    /// The shared `ModelCatalog.localTranscription` identifier.
    public let catalogueID: String
    /// Runtime-neutral name. The catalogue's display name names the Apple
    /// runtime (WhisperKit), which a whisper.cpp host does not run.
    public let displayName: String
    public let summary: String
    /// The GGML tensor type of the pinned weights, such as `f16` or `q5_0`.
    public let quantization: String
    public let multilingual: Bool
    public let artifact: LocalModelFileArtifact

    public var backend: LocalModelBackend { .whisperCppGGML }
}

/// Pinned GGML weights for the catalogue Whisper entries whisper.cpp serves.
///
/// Qualification rule: an entry is listed only when the upstream whisper.cpp
/// project publishes GGML weights of the same Whisper checkpoint, pinned here
/// by repository revision, byte count and SHA-256. The two distilled catalogue
/// entries are deliberately absent: there are no upstream whisper.cpp weights
/// for the distilled turbo checkpoint, and whisper.cpp documents that its
/// decoding of distilled checkpoints does not use their chunked long-form
/// algorithm, so they are not qualified. Adding an entry needs its catalogue
/// identifier, the upstream file's size and digest, and a Windows CI receipt.
public enum WhisperCppModels {
    /// The upstream whisper.cpp model repository and the immutable revision
    /// every URL below is pinned to.
    public static let repository = "ggerganov/whisper.cpp"
    public static let revision = "5359861c739e955e79d9a303bcbc70fb988958b1"

    /// Hugging Face redirects file downloads to regional content hosts that
    /// change over time (for example `us.aws.cdn.hf.co`), so its own domains
    /// are admitted with their subdomains (a leading dot).
    static let huggingFaceHosts: Set<String> = ["huggingface.co", ".huggingface.co", ".hf.co"]

    static let provenance = "OpenAI Whisper weights converted to GGML by the whisper.cpp project "
        + "(huggingface.co/\(repository) at revision \(revision))"

    /// In `ModelCatalog.localTranscription` order.
    public static let all: [WhisperCppModel] = [
        model(
            Pin(catalogueID: "local/whisperkit/tiny", displayName: "Whisper Tiny", file: "ggml-tiny.bin",
                quantization: "f16", bytes: 77_691_713,
                sha256: "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21"),
            summary: "Smallest on-device Whisper model: fastest, lowest accuracy."
        ),
        model(
            Pin(catalogueID: "local/whisperkit/base", displayName: "Whisper Base", file: "ggml-base.bin",
                quantization: "f16", bytes: 147_951_465,
                sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"),
            summary: "Balanced on-device Whisper model for everyday dictation."
        ),
        model(
            Pin(catalogueID: "local/whisperkit/small", displayName: "Whisper Small", file: "ggml-small.bin",
                quantization: "f16", bytes: 487_601_967,
                sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
            summary: "Higher-accuracy on-device Whisper model; fastest with a Vulkan GPU."
        ),
        model(
            Pin(catalogueID: "local/whisperkit/large-v3-turbo", displayName: "Whisper Large v3 Turbo",
                file: "ggml-large-v3-turbo-q5_0.bin", quantization: "q5_0", bytes: 574_041_195,
                sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
            summary: "Near-Large accuracy, 5-bit quantised to about 550 MB. Recommended with a Vulkan GPU."
        )
    ]

    public static func model(forCatalogueID identifier: String) -> WhisperCppModel? {
        let lowered = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.catalogueID == lowered }
    }

    private struct Pin {
        let catalogueID: String
        let displayName: String
        let file: String
        let quantization: String
        let bytes: Int64
        let sha256: String
    }

    private static func model(_ pin: Pin, summary: String) -> WhisperCppModel {
        // Pinned constants: the literal always forms a valid URL.
        let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(pin.file)")!
        return WhisperCppModel(
            catalogueID: pin.catalogueID, displayName: pin.displayName, summary: summary,
            quantization: pin.quantization, multilingual: true,
            artifact: LocalModelFileArtifact(
                url: url, filename: pin.file, byteCount: pin.bytes, sha256: pin.sha256, license: "MIT",
                provenance: provenance
            )
        )
    }
}
