import Foundation

// Deepgram's wire protocol: which endpoint a model speaks and how to read the
// events that come back. Kept beside the client (and out of its body) so the
// URL and parsing rules can be unit-tested without a socket, the way
// `XAILiveProtocol` does for xAI.
extension DeepgramLiveClient {
    /// Whether `model` is one of Deepgram's Flux conversational models, which
    /// speak a different endpoint and event shape from `v1/listen`.
    static func isFluxModel(_ model: String) -> Bool { model.hasPrefix("flux-") }

    /// Builds the streaming URL for `model`.
    ///
    /// Flux models use `v2/listen` and take only the transport parameters (the
    /// v1 formatting/endpointing options are not part of that API); the
    /// multilingual Flux model additionally takes a `language_hint`. Everything
    /// else uses `v1/listen` with interim results and smart formatting.
    static func webSocketURL(model: String, language: String?, sampleRate: Int) -> URL? {
        let isFlux = isFluxModel(model)
        var urlComponents = URLComponents(
            string: isFlux
                ? "wss://api.deepgram.com/v2/listen"
                : "wss://api.deepgram.com/v1/listen"
        )!
        var queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: String(sampleRate))
        ]

        if isFlux {
            if model == "flux-general-multi", let language {
                queryItems.append(URLQueryItem(name: "language_hint", value: language.localeLanguageCode))
            }
        } else {
            queryItems.append(contentsOf: [
                URLQueryItem(name: "punctuate", value: "true"),
                URLQueryItem(name: "smart_format", value: "true"),
                URLQueryItem(name: "numerals", value: "true"),
                URLQueryItem(name: "interim_results", value: "true"),
                URLQueryItem(name: "channels", value: "1"),
                URLQueryItem(name: "endpointing", value: "300"),
                URLQueryItem(name: "vad_events", value: "true")
            ])
            if let language {
                queryItems.append(URLQueryItem(name: "language", value: language.localeLanguageCode))
            }
        }

        urlComponents.queryItems = queryItems
        return urlComponents.url
    }

    /// Decodes one Deepgram message into a transcript update, or `nil` for
    /// frames that carry no words (keepalives, metadata, empty transcripts).
    static func transcriptEvent(from json: String, model: String) -> (text: String, isFinal: Bool)? {
        guard let data = json.data(using: .utf8) else { return nil }

        if isFluxModel(model) {
            guard
                let response = try? JSONDecoder().decode(DeepgramFluxResponse.self, from: data),
                !response.transcript.isEmpty
            else {
                return nil
            }
            // Flux streams a running `Update` per turn and closes it with
            // `EndOfTurn`, which is the turn's finalised text.
            return (response.transcript, response.event == "EndOfTurn")
        }

        guard
            let response = try? JSONDecoder().decode(DeepgramStreamResponse.self, from: data),
            let channel = response.channel,
            let alternative = channel.alternatives.first,
            !alternative.transcript.isEmpty
        else {
            return nil
        }
        return (alternative.transcript, response.is_final ?? false)
    }

    /// Whether this frame is the `Metadata` message Deepgram sends last, after
    /// `CloseStream` — the signal that no further transcript is coming.
    static func isMetadataFrame(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(DeepgramStreamResponse.self, from: data) else {
            return false
        }
        return response.type == "Metadata"
    }
}

// MARK: - Response Models

/// Flux (`v2/listen`) turn event: `Update` while a turn is in progress,
/// `EndOfTurn` when Deepgram has finalised it.
struct DeepgramFluxResponse: Decodable {
    let event: String
    let transcript: String
}

struct DeepgramStreamResponse: Decodable {
    struct Alternative: Decodable {
        let transcript: String
        let confidence: Double?
    }

    struct Channel: Decodable {
        let alternatives: [Alternative]
    }

    let type: String?
    let channel: Channel?
    // swiftlint:disable:next identifier_name
    let is_final: Bool?
}
