import Foundation

/// Shared catalogue metadata for NVIDIA Nemotron 3.5 ASR served by the
/// sherpa-onnx runtime (macOS Developer ID builds).
///
/// `nvidia/nemotron-3.5-asr-streaming-0.6b` is the multilingual successor of
/// the English Nemotron streaming model: a 600M cache-aware FastConformer-RNNT
/// conditioned on a language-ID prompt, with native punctuation and casing.
/// The artifacts pinned here are the int8 ONNX exports published by the
/// sherpa-onnx project; the NeMo checkpoint itself is not runnable by the app.
public enum NemotronLocalModels {
    public static let repoID = "k2-fsa/sherpa-onnx"

    /// Export family shared by every chunk size, used for runtime matching.
    public static let multilingualFamily = "nemotron-3.5-asr-streaming-0.6b"

    public struct Variant: Sendable, Equatable {
        public let modelName: String
        public let chunkMilliseconds: Int
        /// SHA256 of the GitHub release asset, checked after download.
        public let archiveSHA256: String

        public var archiveURL: URL? {
            URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(modelName).tar.bz2")
        }
    }

    /// Release asset digests were read from the GitHub `asr-models` release;
    /// the 560 ms digest was also reproduced from an independent download.
    public static let multilingual1120ms = Variant(
        modelName: "sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-1120ms-int8-2026-06-11",
        chunkMilliseconds: 1120,
        archiveSHA256: "adbdd5e9fef87300c37cebfcfc4f1ebe56845c860c8a760af0a1dd65ce9beed3"
    )

    public static let multilingual560ms = Variant(
        modelName: "sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8-2026-06-11",
        chunkMilliseconds: 560,
        archiveSHA256: "c6bf5e0df765f9d5b43bc9e0536d4b4b3e7d40bdf5ecf13e45f134c51c05ae3a"
    )

    public static let multilingualVariants = [multilingual1120ms, multilingual560ms]

    /// Compressed download is ~453 MB; unpacked int8 weights are ~670 MB.
    public static let multilingualDownloadSizeMB = 453
    public static let multilingualInstalledSizeMB = 670

    /// Measured peak resident memory with the 560 ms int8 export (sherpa-onnx
    /// 1.13.5, 2 CPU threads, Apple M2 Pro): ~1.3 GB.
    public static let multilingualApproximateRAMMB = 1_330

    /// The language-ID prompt and its decoder hook first shipped in sherpa-onnx
    /// 1.13.3; the exports were re-published for 1.13.5, the version measured.
    public static let minimumRuntimeVersion = "1.13.5"

    /// NVIDIA publishes the checkpoint under the OpenMDW-1.1 licence.
    public static let multilingualLicense = "OpenMDW-1.1"

    /// Locale tags in the export's tokenizer that NVIDIA lists as transcription-ready
    /// or broad-coverage. The eight adaptation-ready locales need fine-tuning, so
    /// they fall back to automatic detection rather than forcing a weak prompt.
    public static let supportedLocaleTags: [String] = [
        "en-US", "en-GB", "es-US", "es-ES", "fr-FR", "fr-CA", "it-IT", "pt-BR", "pt-PT",
        "nl-NL", "de-DE", "tr-TR", "ru-RU", "ar-AR", "hi-IN", "ja-JP", "ko-KR", "vi-VN",
        "uk-UA", "pl-PL", "sv-SE", "cs-CZ", "nb-NO", "da-DK", "bg-BG", "fi-FI", "hr-HR",
        "sk-SK", "zh-CN", "hu-HU", "ro-RO", "et-EE"
    ]

    public static func isMultilingual(_ text: String) -> Bool {
        text.lowercased().contains(multilingualFamily)
    }

    public static func variant(named modelName: String) -> Variant? {
        multilingualVariants.first { $0.modelName.caseInsensitiveCompare(modelName) == .orderedSame }
    }

    /// The per-stream language prompt for an app locale, or `nil` to let the
    /// model auto-detect. An exact supported tag wins; otherwise a supported
    /// bare language code is passed and the runtime picks its default locale.
    public static func languageHint(forLocaleIdentifier identifier: String?) -> String? {
        guard let identifier else { return nil }
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty, normalized.lowercased() != "auto" else { return nil }
        if let exact = supportedLocaleTags.first(where: {
            $0.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return exact
        }
        var language = normalized.split(separator: "-").first.map { String($0).lowercased() } ?? ""
        if language == "no" { language = "nb" }
        let supportedLanguages = Set(supportedLocaleTags.map { $0.prefix(2).lowercased() })
        return supportedLanguages.contains(language) ? language : nil
    }

    public static let settingsSummary = """
        32 language-locales with automatic detection or your selected language · punctuation + \
        capitalisation · needs ~1.3 GB free RAM while active · needs sherpa-onnx \
        \(minimumRuntimeVersion)+ · OpenMDW-1.1 licence (NVIDIA).
        """
}
