import Foundation

/// A downloadable GGUF language model for local transcript cleanup,
/// identified under `local/post-processing/`.
///
/// The Codable form is persisted in `imported-hugging-face-gguf-models.json`
/// and data-migration archives; keep its field names, including the optional
/// `approximateSizeMB` (omitted when unknown). A decoded `id` is kept verbatim.
public struct LocalPostProcessingModel: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let repoID: String
    public let filename: String
    public let approximateSizeMB: Int?
    public let description: String

    public init(
        id: String? = nil,
        displayName: String,
        repoID: String,
        filename: String,
        approximateSizeMB: Int?,
        description: String
    ) {
        self.id = id ?? Self.huggingFaceModelID(repoID: repoID, filename: filename)
        self.displayName = displayName
        self.repoID = repoID
        self.filename = filename
        self.approximateSizeMB = approximateSizeMB
        self.description = description
    }

    public var option: ModelCatalog.Option {
        ModelCatalog.Option(
            id: id,
            displayName: displayName,
            description: description,
            estimatedLatencyMs: 2_500,
            latencyTier: .medium,
            tags: [.privacy],
            pricing: nil,
            contextLength: 4_096
        )
    }

    /// llama.cpp for a GGUF file; `nil` for anything no backend can run.
    public var backend: LocalModelBackend? {
        Self.isGGUFFilename(filename) ? .llamaCppGGUF : nil
    }
}

public extension LocalPostProcessingModel {
    /// Built-in rules cleanup shares the namespace but is not a download.
    static let builtInRulesModelID = "local/post-processing/rules"

    static func isDownloadedModelID(_ id: String) -> Bool {
        id.lowercased().hasPrefix(LocalModelIdentity.postProcessingPrefix)
            && id.lowercased() != builtInRulesModelID
    }

    static func huggingFaceModelID(repoID: String, filename: String) -> String {
        LocalModelIdentity.postProcessingHuggingFaceModelID(repoID: repoID, filename: filename)
    }

    static func isGGUFFilename(_ filename: String) -> Bool {
        filename.lowercased().hasSuffix(".gguf")
    }

    /// The first size such as `1.5GB` or `350 MB` in a filename, where one GB
    /// is 1024 MB; `nil` when the name carries none.
    static func approximateSizeMB(fromFilename filename: String) -> Int? {
        let lower = filename.lowercased()
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*(gb|mb)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let valueRange = Range(match.range(at: 1), in: lower),
              let unitRange = Range(match.range(at: 2), in: lower),
              let value = Double(lower[valueRange])
        else {
            return nil
        }
        let multiplier = lower[unitRange] == "gb" ? 1024.0 : 1.0
        return Int((value * multiplier).rounded())
    }

    static func importedDisplayName(repoID: String, filename: String) -> String {
        let base = filename
            .replacingOccurrences(of: ".gguf", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        return "\(base) from \(repoID)"
    }

    /// The entry for a Hugging Face import. Pass the trimmed, validated
    /// `owner/repo` and GGUF filename; a missing size is parsed from the name.
    static func importedModel(repoID: String, filename: String, approximateSizeMB: Int?) -> LocalPostProcessingModel {
        LocalPostProcessingModel(
            displayName: importedDisplayName(repoID: repoID, filename: filename),
            repoID: repoID,
            filename: filename,
            approximateSizeMB: approximateSizeMB ?? Self.approximateSizeMB(fromFilename: filename),
            description: "Imported from Hugging Face. Runs locally through the llama.cpp post-processing runtime."
        )
    }
}
