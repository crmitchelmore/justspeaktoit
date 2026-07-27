import Foundation

/// Canonical AssemblyAI model identifiers and Streaming v3 request construction.
///
/// Keep provider-facing names here so the shared catalogue, macOS provider, and
/// iOS streaming client cannot drift when AssemblyAI replaces a model generation.
public enum AssemblyAIModels {
    public static let universal35ProAPIName = "universal-3-5-pro"
    public static let universal35ProBatchID = "assemblyai/\(universal35ProAPIName)"
    public static let universal35ProStreamingID = "assemblyai/\(universal35ProAPIName)-streaming"

    public static let universal2APIName = "universal-2"
    public static let universal2BatchID = "assemblyai/\(universal2APIName)"

    /// Saved selections that should follow the in-place Universal-3.5 Pro upgrade.
    public static let legacyUniversal3BatchIDs: Set<String> = [
        "assemblyai/universal-3-pro",
        "universal-3-pro"
    ]

    /// Includes every AssemblyAI live identifier shipped before Universal-3.5 Pro.
    public static let legacyUniversal3StreamingIDs: Set<String> = [
        "assemblyai/u3-rt-pro-streaming",
        "assemblyai/u3-rt-pro",
        "u3-rt-pro-streaming",
        "u3-rt-pro",
        "assemblyai/universal-streaming",
        "assemblyai/universal-streaming-english",
        "assemblyai/universal-streaming-multilingual",
        "universal-streaming",
        "universal-streaming-english",
        "universal-streaming-multilingual"
    ]
}

public enum AssemblyAIStreamingEndpoint: String, Sendable {
    case europe = "streaming.eu.assemblyai.com"
    case global = "streaming.assemblyai.com"
}

public enum AssemblyAIStreamingRequest {
    /// Preserve the app's existing turn boundary while moving to the new model.
    public static let minimumTurnSilenceMilliseconds = 560

    /// Builds a Universal-3.5 Pro Streaming v3 URL for both Apple platforms.
    ///
    /// `format_turns` and `language_detection` are deliberately absent:
    /// Universal-3.5 Pro always formats final turns and detects its supported
    /// languages natively. Keyterms remain a single JSON-array query parameter.
    public static func url(
        endpoint: AssemblyAIStreamingEndpoint,
        apiKey: String,
        sampleRate: Int,
        speechModel: String = AssemblyAIModels.universal35ProAPIName,
        keyterms: [String] = []
    ) -> URL? {
        guard var components = URLComponents(string: "wss://\(endpoint.rawValue)/v3/ws") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "encoding", value: "pcm_s16le"),
            URLQueryItem(name: "speech_model", value: speechModel),
            URLQueryItem(
                name: "min_turn_silence",
                value: String(minimumTurnSilenceMilliseconds)
            ),
            // The query token is retained for URLSession WebSocket reliability;
            // clients also send the documented Authorization header.
            URLQueryItem(name: "token", value: apiKey)
        ]

        let validTerms = Array(keyterms.filter { !$0.isEmpty && $0.count <= 50 }.prefix(100))
        if !validTerms.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: validTerms),
           let json = String(data: data, encoding: .utf8) {
            components.queryItems?.append(URLQueryItem(name: "keyterms_prompt", value: json))
        }
        return components.url
    }
}
