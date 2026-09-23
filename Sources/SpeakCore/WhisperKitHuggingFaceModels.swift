import Foundation

/// A Hugging Face model name resolved to the variant WhisperKit downloads.
public struct ResolvedHuggingFaceModel: Equatable, Sendable {
    public let modelName: String
    public let displayName: String
    public let approximateSizeMB: Int

    public init(modelName: String, displayName: String, approximateSizeMB: Int) {
        self.modelName = modelName
        self.displayName = displayName
        self.approximateSizeMB = approximateSizeMB
    }
}

/// Import and migration rules for WhisperKit models imported from Hugging Face.
///
/// An imported identifier derives from the *resolved* model name, so a shorthand
/// such as `tiny` and its exact variant share one install marker. Identifiers
/// persisted before an alias existed migrate through `normalizedModelID(_:)` and
/// `normalizedImportedModel(_:)`. The resulting entries need Core ML
/// (`LocalModelBackend.whisperKitCoreML`) wherever their metadata is read.
public enum WhisperKitHuggingFaceModels {
    /// The only repository whose shorthand names resolve to exact variants.
    public static let argmaxRepoID = "argmaxinc/whisperkit-coreml"

    public static func modelID(repoID: String, modelName: String) -> String {
        LocalModelIdentity.whisperKitHuggingFaceModelID(repoID: repoID, modelName: modelName)
    }

    /// The catalogue entry for an import. Pass the trimmed, validated
    /// `owner/repo` and model name; the result is persisted as supplied.
    public static func importedModel(repoID: String, modelName: String) -> LocalTranscriptionModel {
        let resolved = resolve(repoID: repoID, modelName: modelName)
        return LocalTranscriptionModel(
            id: modelID(repoID: repoID, modelName: resolved.modelName),
            displayName: importedDisplayName(resolved, repoID: repoID),
            modelName: resolved.modelName,
            engine: .whisperKit,
            modelRepo: repoID,
            approximateSizeMB: resolved.approximateSizeMB,
            description: "Imported from Hugging Face. WhisperKit will download the matching Core ML files from "
                + "\(repoID).",
            tags: [.quality]
        )
    }

    /// Migrates a persisted `local/whisperkit/huggingface/...` identifier to
    /// the one its resolved model name now derives. Other identifiers,
    /// including catalogue and Apple Speech IDs, are only trimmed.
    public static func normalizedModelID(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = LocalModelIdentity.whisperKitHuggingFacePrefix
        guard trimmed.lowercased().hasPrefix(prefix) else { return trimmed }

        let remainder = String(trimmed.dropFirst(prefix.count))
        let components = remainder.split(separator: "/").map(String.init)
        guard components.count >= 3 else { return trimmed }

        let repoID = "\(components[0])/\(components[1])"
        let modelSlug = components.dropFirst(2).joined(separator: "/")
        let resolved = resolve(repoID: repoID, modelName: modelSlug)
        return modelID(repoID: repoID, modelName: resolved.modelName)
    }

    /// Returns `model` unchanged unless its identifier, model name or size is
    /// stale for its repository. Description, tags, engine and live-streaming
    /// support are always kept.
    public static func normalizedImportedModel(_ model: LocalTranscriptionModel) -> LocalTranscriptionModel {
        guard let repoID = model.modelRepo else { return model }
        let resolved = resolve(repoID: repoID, modelName: model.modelName)
        let expectedID = modelID(repoID: repoID, modelName: resolved.modelName)
        guard expectedID != model.id
            || resolved.modelName != model.modelName
            || resolved.approximateSizeMB != model.approximateSizeMB
        else {
            return model
        }
        return LocalTranscriptionModel(
            id: expectedID,
            displayName: importedDisplayName(resolved, repoID: repoID),
            modelName: resolved.modelName,
            engine: model.engine,
            modelRepo: model.modelRepo,
            approximateSizeMB: resolved.approximateSizeMB,
            description: model.description,
            tags: model.tags,
            supportsLiveStreaming: model.supportsLiveStreaming
        )
    }

    /// Resolves Argmax shorthands to exact variants. Any other name is kept,
    /// trimmed, with a size parsed from a trailing `_<n>MB` component (or 0).
    public static func resolve(repoID: String, modelName: String) -> ResolvedHuggingFaceModel {
        let repo = repoID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if repo == argmaxRepoID, let known = knownArgmaxModels[trimmedName.lowercased()] {
            return known
        }
        return ResolvedHuggingFaceModel(
            modelName: trimmedName,
            displayName: trimmedName,
            approximateSizeMB: sizeFromModelName(trimmedName) ?? 0
        )
    }

    private static func importedDisplayName(_ resolved: ResolvedHuggingFaceModel, repoID: String) -> String {
        "\(resolved.displayName) from \(repoID)"
    }

    private static func sizeFromModelName(_ modelName: String) -> Int? {
        let suffix = modelName.split(separator: "_").last.map(String.init) ?? ""
        guard suffix.lowercased().hasSuffix("mb") else { return nil }
        return Int(suffix.dropLast(2))
    }

    private static let knownArgmaxModels: [String: ResolvedHuggingFaceModel] = {
        func model(
            _ aliases: [String],
            name: String,
            displayName: String,
            size: Int
        ) -> [(String, ResolvedHuggingFaceModel)] {
            aliases.map {
                (
                    $0,
                    ResolvedHuggingFaceModel(modelName: name, displayName: displayName, approximateSizeMB: size)
                )
            }
        }

        let models = [
            model(
                ["tiny", "whisper-tiny", "openai_whisper-tiny"],
                name: "openai_whisper-tiny",
                displayName: "Whisper Tiny",
                size: 75
            ),
            model(
                ["base", "whisper-base", "openai_whisper-base"],
                name: "openai_whisper-base",
                displayName: "Whisper Base",
                size: 145
            ),
            model(
                ["small", "whisper-small", "openai_whisper-small", "openai_whisper-small_216mb"],
                name: "openai_whisper-small_216MB",
                displayName: "Whisper Small",
                size: 216
            ),
            model(
                ["distil-large-v3", "distil-whisper_distil-large-v3", "distil-whisper_distil-large-v3_594mb"],
                name: "distil-whisper_distil-large-v3_594MB",
                displayName: "Distil-Whisper Large v3",
                size: 594
            ),
            model(
                [
                    "distil-large-v3-turbo",
                    "distil-large-v3_turbo",
                    "distil-whisper_distil-large-v3_turbo",
                    "distil-whisper_distil-large-v3_turbo_600mb"
                ],
                name: "distil-whisper_distil-large-v3_turbo_600MB",
                displayName: "Distil-Whisper Large v3 Turbo",
                size: 600
            ),
            model(
                [
                    "large-v3-turbo",
                    "large-v3_turbo",
                    "openai_whisper-large-v3-v20240930_turbo",
                    "openai_whisper-large-v3-v20240930_turbo_632mb"
                ],
                name: "openai_whisper-large-v3-v20240930_turbo_632MB",
                displayName: "Whisper Large v3 Turbo",
                size: 632
            ),
            model(
                [
                    "openai_whisper-large-v3_turbo",
                    "openai_whisper-large-v3_turbo_954mb",
                    "openai-whisper-large-v3-turbo",
                    "openai-whisper-large-v3-turbo-954mb"
                ],
                name: "openai_whisper-large-v3_turbo_954MB",
                displayName: "Whisper Large v3 Turbo",
                size: 954
            )
        ].flatMap { $0 }

        return Dictionary(uniqueKeysWithValues: models)
    }()
}
