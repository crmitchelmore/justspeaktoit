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

    public var message: String {
        switch self {
        case .emptyName:
            return "Give the profile a name."
        case .unknownStreamingProvider(let modelID):
            return "“\(modelID)” is not a streaming model the app can route to. "
                + "Use a provider/model identifier from a supported live provider, or pick a catalogue model."
        case .unsupportedPolishModel(let modelID):
            return "“\(modelID)” is not a polish model the app can run. Pick a catalogue model."
        }
    }
}

public enum DictationProfileValidator {
    public static func issues(for profile: DictationProfile) -> [DictationProfileIssue] {
        var issues: [DictationProfileIssue] = []
        if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyName)
        }
        if let override = profile.resolvedTranscriptionOverride,
           override.routing == .remoteStreaming,
           !isRoutableStreamingModel(override.modelID) {
            issues.append(.unknownStreamingProvider(modelID: override.modelID))
        }
        if let polishModel = trimmedNonEmpty(profile.polishModelID), !isSupportedPolishModel(polishModel) {
            issues.append(.unsupportedPolishModel(modelID: polishModel))
        }
        return issues
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
