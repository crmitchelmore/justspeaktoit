import Foundation

/// Shared catalogue metadata for NVIDIA Parakeet models served by the
/// sherpa-onnx runtime (macOS Developer ID builds).
///
/// Parakeet v3 (`parakeet-tdt-0.6b-v3`) is an offline NeMo TDT transducer:
/// it transcribes 25 European languages with automatic language detection and
/// emits punctuation and capitalisation natively. The artifact pinned here is
/// the int8 ONNX export published by the sherpa-onnx project.
public enum ParakeetLocalModels {
    /// Stable local streaming source ID. Must stay in sync with the ID
    /// `LocalStreamingModelSource` derives from `tdtV3Int8RepoID` and
    /// `tdtV3Int8ModelName` (covered by a SpeakApp test).
    public static let tdtV3Int8SourceID =
        "local/streaming/huggingface/k2-fsa/sherpa-onnx/sherpa-onnx-nemo-parakeet-tdt-0-6b-v3-int8"

    public static let tdtV3Int8RepoID = "k2-fsa/sherpa-onnx"
    public static let tdtV3Int8ModelName = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"
    public static let tdtV3DisplayName = "Parakeet v3 (0.6B)"

    /// Canonical int8 archive from the sherpa-onnx `asr-models` GitHub release.
    /// A non-quantised fp32 export also exists on Hugging Face
    /// (`csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3`, ~2.4 GB); the int8
    /// variant is what peer apps ship and is the recommended default.
    public static let tdtV3Int8ArchiveURLString =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/"
            + "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2"

    public static var tdtV3Int8ArchiveURL: URL? {
        URL(string: tdtV3Int8ArchiveURLString)
    }

    /// SHA256 of the pinned archive, verified against the GitHub release asset
    /// digest and an independent local download.
    public static let tdtV3Int8ArchiveSHA256 =
        "5793d0fd397c5778d2cf2126994d58e9d56b1be7c04d13c7a15bb1b4eafb16bf"

    /// Compressed download is ~465 MB; the unpacked ONNX weights are ~670 MB.
    public static let tdtV3Int8DownloadSizeMB = 465
    public static let tdtV3Int8InstalledSizeMB = 670

    /// Measured peak resident memory while the int8 recognizer is loaded and
    /// decoding (sherpa-onnx 1.13.2, 2 threads): just under 2 GB.
    public static let tdtV3ApproximateRAMMB = 2048

    /// ISO 639-1 codes for the 25 European languages Parakeet v3 transcribes.
    /// No language selection is needed: the model auto-detects the language.
    public static let tdtV3LanguageCodes: [String] = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr",
        "hr", "hu", "it", "lt", "lv", "mt", "nl", "pl", "pt", "ro",
        "ru", "sk", "sl", "sv", "uk"
    ]

    public static let tdtV3SupportsLanguageAutoDetection = true

    /// NVIDIA publishes parakeet-tdt-0.6b-v3 under CC-BY-4.0.
    public static let tdtV3License = "CC-BY-4.0"

    public static let tdtV3Description = """
        NVIDIA Parakeet v3 (TDT 0.6B, int8) — fast multilingual local dictation across \
        25 European languages with automatic language detection, punctuation and \
        capitalisation. Served by the sherpa-onnx runtime.
        """

    /// Compact summary line for settings surfaces: languages, RAM guidance and
    /// licence note.
    public static let tdtV3SettingsSummary = """
        25 European languages with automatic detection · punctuation + capitalisation · \
        needs ~2 GB free RAM while active · CC-BY-4.0 licence (NVIDIA).
        """
}
