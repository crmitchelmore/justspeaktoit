import Foundation

/// Stable identifiers for downloaded local models.
///
/// Downloaded models live under `local/...`; Apple Speech keeps `apple/local/...`.
/// Identifiers are persisted in settings, profiles, History, install markers and
/// imported-model catalogues, so each derivation here is a storage format:
/// changing one orphans existing downloads and selections.
public enum LocalModelIdentity {
    public static let whisperKitHuggingFacePrefix = "local/whisperkit/huggingface/"
    public static let streamingHuggingFacePrefix = "local/streaming/huggingface/"
    public static let postProcessingPrefix = "local/post-processing/"
    public static let postProcessingHuggingFacePrefix = "local/post-processing/huggingface/"

    /// Lowercases and replaces everything except letters, numbers, `-` and `/`
    /// with `-`. The result is lossy: keep the original repository and model
    /// names wherever a label is shown.
    public static func slug(_ value: String) -> String {
        value
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber || character == "-" || character == "/" ? character : "-"
            }
            .reduce(into: "") { result, character in result.append(character) }
    }

    public static func whisperKitHuggingFaceModelID(repoID: String, modelName: String) -> String {
        "\(whisperKitHuggingFacePrefix)\(slug(repoID))/\(slug(modelName))"
    }

    public static func streamingSourceID(repoID: String, modelName: String) -> String {
        "\(streamingHuggingFacePrefix)\(slug(repoID))/\(slug(modelName))"
    }

    public static func postProcessingHuggingFaceModelID(repoID: String, filename: String) -> String {
        "\(postProcessingHuggingFacePrefix)\(slug(repoID))/\(slug(filename))"
    }
}
