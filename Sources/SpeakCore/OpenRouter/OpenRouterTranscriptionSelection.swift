import Foundation

/// Stable preference identifiers distinguish dedicated OpenRouter STT from direct provider and audio-chat routes.
public enum OpenRouterTranscriptionSelection {
    public static let prefix = "openrouter/transcription/"

    public static func identifier(for modelID: String) -> String {
        prefix + modelID
    }

    public static func modelID(from identifier: String) -> String? {
        guard identifier.hasPrefix(prefix) else { return nil }
        let modelID = String(identifier.dropFirst(prefix.count))
        return isValidModelID(modelID) ? modelID : nil
    }

    /// The same bounded raw identifier contract applies to discovery, saved selections, and both audio endpoints.
    static func isValidModelID(_ modelID: String) -> Bool {
        let components = modelID.split(separator: "/", omittingEmptySubsequences: false)
        return modelID.utf8.count <= 512 && components.count >= 2 && components.allSatisfy({ !$0.isEmpty })
            && modelID.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
    }
}
