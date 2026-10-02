import Foundation

struct SonioxStreamResponse: Decodable {
    let tokens: [SonioxToken]?
    let finished: Bool?
    let errorCode: Int?
    let errorMessage: String?

    var tokenSummary: SonioxTokenSummary {
        var finals = ""
        var nonFinals = ""
        var sawMarker = false
        for token in tokens ?? [] {
            if token.text == "<fin>" || token.text == "<end>" {
                sawMarker = true
            } else if token.isFinal == true {
                finals.append(token.text)
            } else {
                nonFinals.append(token.text)
            }
        }
        return SonioxTokenSummary(finals: finals, nonFinals: nonFinals, sawMarker: sawMarker)
    }

    enum CodingKeys: String, CodingKey {
        case tokens, finished
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
}

/// The finals/non-finals split of one Soniox frame, plus whether that frame
/// carried an end-of-utterance marker.
struct SonioxTokenSummary {
    let finals: String
    let nonFinals: String
    let sawMarker: Bool
}

struct SonioxToken: Decodable {
    let text: String
    let isFinal: Bool?

    enum CodingKeys: String, CodingKey {
        case text
        case isFinal = "is_final"
    }
}

extension SonioxLiveClient {
    /// Maps a transport failure carrying an HTTP credential rejection, numeric or
    /// textual, to the invalid-key error so callers can offer key recovery.
    func mapConnectionError(_ error: Error) -> Error {
        let nsError = error as NSError
        let description = nsError.localizedDescription.lowercased()
        if nsError.code == 401 || nsError.code == 403
            || description.contains("401") || description.contains("403")
            || description.contains("unauthorized") || description.contains("forbidden") {
            return StreamingClientError.invalidAPIKey(provider: "Soniox")
        }
        return error
    }
}
