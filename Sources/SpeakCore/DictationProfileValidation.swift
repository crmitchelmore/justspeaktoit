import Foundation

/// A reason a dictation profile cannot execute as configured. The editor
/// refuses to save a profile with issues, and the session applier skips the
/// parts it cannot honour, so a saved profile always runs the way it was
/// displayed (issue #690).
public enum DictationProfileIssue: Equatable, Sendable {
    case emptyName
    /// A streaming override whose identifier does not belong to a live-transcription
    /// provider the app can route to.
    case unknownStreamingProvider(modelID: String)
    /// A polish model the post-processing pipeline would silently replace with the
    /// default model.
    case unsupportedPolishModel(modelID: String)
    /// A local-model override whose identifier is not a downloaded local model.
    case unknownLocalModel(modelID: String)
    /// A local model stored under remote routing: the session would send a local
    /// identifier to a cloud provider.
    case localModelUnderRemoteRouting(modelID: String)

    public var message: String {
        switch self {
        case .emptyName:
            return "Give the profile a name."
        case .unknownStreamingProvider(let modelID):
            return "“\(modelID)” is not a streaming model the app can route to. "
                + "Use a provider/model identifier from a supported live provider, or pick a catalogue model."
        case .unsupportedPolishModel(let modelID):
            return "“\(modelID)” is not a polish model the app can run. Pick a catalogue model."
        case .unknownLocalModel(let modelID):
            return "“\(modelID)” is not a local model the app can run. Pick a downloaded model."
        case .localModelUnderRemoteRouting(let modelID):
            return "“\(modelID)” is a local model. Choose Local Model routing for it."
        }
    }
}

public enum DictationProfileValidator {
    public static func issues(for profile: DictationProfile) -> [DictationProfileIssue] {
        var issues: [DictationProfileIssue] = []
        if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyName)
        }
        if let override = profile.resolvedTranscriptionOverride {
            issues.append(contentsOf: transcriptionIssues(modelID: override.modelID, routing: override.routing))
        }
        if let polishModel = trimmedNonEmpty(profile.polishModelID), !isSupportedPolishModel(polishModel) {
            issues.append(.unsupportedPolishModel(modelID: polishModel))
        }
        return issues
    }

    /// Routing and identifier must agree: a local identifier only runs under local
    /// routing, and local routing only runs a local identifier.
    private static func transcriptionIssues(
        modelID: String,
        routing: DictationProfileTranscriptionRouting
    ) -> [DictationProfileIssue] {
        switch routing {
        case .remoteStreaming:
            return isRoutableStreamingModel(modelID) ? [] : [.unknownStreamingProvider(modelID: modelID)]
        case .remoteBatch:
            return isLocalModel(modelID) ? [.localModelUnderRemoteRouting(modelID: modelID)] : []
        case .localBatch:
            return isLocalModel(modelID) ? [] : [.unknownLocalModel(modelID: modelID)]
        }
    }

    /// Whether `modelID` is a downloaded-model identifier the local batch pipeline runs.
    public static func isLocalModel(_ modelID: String) -> Bool {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("local/")
    }

    /// Whether the live-transcription pipeline can start `modelID`: a catalogue entry, or a
    /// custom identifier under a known live provider prefix.
    public static func isRoutableStreamingModel(_ modelID: String) -> Bool {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if ModelCatalog.liveTranscription.contains(where: { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return true
        }
        return LiveTranscriptionRouting.route(for: trimmed) != nil
    }

    /// Whether the post-processing pipeline runs `modelID` as given — exactly the
    /// identifiers `ModelCatalog.normalizedPostProcessingModel` preserves.
    public static func isSupportedPolishModel(_ modelID: String) -> Bool {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return ModelCatalog.normalizedPostProcessingModel(trimmed) == trimmed
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
