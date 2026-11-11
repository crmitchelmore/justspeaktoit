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

    /// Downloaded Whisper batch models; the Mac's WhisperKit and the desktop
    /// hosts' whisper.cpp pins share these catalogue identifiers.
    public static let whisperBatchPrefix = "local/whisperkit/"
    /// Live (streaming) use of a downloaded Whisper batch model. Persisted as
    /// the Mac's `localStreamingModelSource` and as desktop live selections.
    public static let whisperLivePrefix = "local/streaming/whisperkit/"

    /// The live identifier that streams with a downloaded Whisper batch model.
    public static func whisperLiveModelID(forBatchModelID modelID: String) -> String {
        guard modelID.hasPrefix(whisperBatchPrefix) else { return whisperLivePrefix + modelID }
        return whisperLivePrefix + modelID.dropFirst(whisperBatchPrefix.count)
    }

    /// The batch model a live Whisper identifier streams with, or nil for any
    /// other identifier.
    public static func whisperBatchModelID(fromLiveModelID liveID: String) -> String? {
        guard liveID.hasPrefix(whisperLivePrefix) else { return nil }
        return whisperBatchPrefix + liveID.dropFirst(whisperLivePrefix.count)
    }
}
