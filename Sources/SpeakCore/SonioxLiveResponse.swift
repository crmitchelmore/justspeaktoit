import Foundation

struct SonioxStreamResponse: Decodable {
    let tokens: [SonioxToken]?
    let finished: Bool?
    let errorCode: Int?
    let errorMessage: String?

    var tokenSummary: (finals: String, nonFinals: String, sawMarker: Bool) {
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
        return (finals, nonFinals, sawMarker)
    }

    enum CodingKeys: String, CodingKey {
        case tokens, finished
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }
}

struct SonioxToken: Decodable {
    let text: String
    let isFinal: Bool?

    enum CodingKeys: String, CodingKey {
        case text
        case isFinal = "is_final"
    }
}
