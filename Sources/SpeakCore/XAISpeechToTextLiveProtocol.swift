import Foundation

/// The `wss://api.x.ai/v1/stt` session shape: the URL its query items
/// configure, and how a server error is classified.
///
/// Kept beside the client rather than inside it: these are pure functions of
/// the protocol, with no connection state, and they are what the tests drive
/// directly.
extension XAISpeechToTextLiveClient {
    /// `wss://api.x.ai/v1/stt` with the session configured entirely by query
    /// items — there is no start message and no `model` parameter.
    static func webSocketURL(
        sampleRate: Int,
        language: String?,
        keywords: [String] = []
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = XAISpeechToText.webSocketHost
        components.path = XAISpeechToText.webSocketPath
        var items = [
            URLQueryItem(name: "encoding", value: "pcm"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate)),
            URLQueryItem(name: "interim_results", value: "true")
        ]
        if let code = XAISpeechToText.languageCode(for: language) {
            items.append(URLQueryItem(name: "language", value: code))
        }
        // Repeated `keyterm` items, which is how the service takes a list.
        items += XAISpeechToText.boundedKeyterms(keywords).map {
            URLQueryItem(name: "keyterm", value: $0)
        }
        components.queryItems = items
        return components.url
    }

    static func error(fromServerMessage rawMessage: String) -> Error {
        // The frame's text is provider-supplied and can echo submitted speech,
        // so classification reads the raw value but nothing user-visible
        // carries more than a bounded, single-line version of it.
        let message = XAISpeechToTextError.boundedMessage(rawMessage)
        let lowered = rawMessage.lowercased()
        if lowered.contains("unauthorized") || lowered.contains("api key")
            || lowered.contains("forbidden") || lowered.contains("401")
            || lowered.contains("403") {
            return StreamingClientError.invalidAPIKey(provider: "xAI")
        }
        if lowered.contains("credit") || lowered.contains("quota")
            || lowered.contains("balance") {
            return XAISpeechToTextError.quotaExceeded(message: message)
        }
        if lowered.contains("rate limit") || lowered.contains("429") {
            return XAISpeechToTextError.rateLimited(message: message)
        }
        return XAISpeechToTextError.server(message: message)
    }

    func mapConnectionError(_ error: Error) -> Error {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        if description.contains("401") || description.contains("403")
            || description.contains("unauthorized") || description.contains("forbidden") {
            return StreamingClientError.invalidAPIKey(provider: "xAI")
        }
        return error
    }
}
