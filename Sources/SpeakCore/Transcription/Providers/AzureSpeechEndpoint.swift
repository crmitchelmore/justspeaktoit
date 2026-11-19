import Foundation

/// Builds a regional Azure endpoint without interpreting credential input as URL syntax.
public enum AzureSpeechEndpoint {
    public static func baseURL(region: String) -> URL? {
        let normalized = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty, normalized.utf8.count <= 63,
              normalized.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) })
        else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = normalized + ".tts.speech.microsoft.com"
        return components.url
    }
}
