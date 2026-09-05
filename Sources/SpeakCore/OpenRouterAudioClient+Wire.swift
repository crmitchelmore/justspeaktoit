import Foundation

struct OpenRouterTranscriptionRequest: Encodable {
    struct InputAudio: Encodable {
        let data: String
        let format: String
    }

    let model: String
    let inputAudio: InputAudio
    let language: String?
    let responseFormat = "json"

    enum CodingKeys: String, CodingKey {
        case model, language
        case inputAudio = "input_audio"
        case responseFormat = "response_format"
    }
}

struct OpenRouterSpeechRequest: Encodable {
    let model: String
    let input: String
    let voice: String?
    let speed: Double?
    let responseFormat = "mp3"

    enum CodingKeys: String, CodingKey {
        case model, input, voice, speed
        case responseFormat = "response_format"
    }
}

struct OpenRouterTranscriptionResponse: Decodable {
    struct Usage: Decodable {
        let seconds: Double?
        let cost: Decimal?
        let inputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case seconds, cost
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    let text: String
    let usage: Usage?

    func result(model: String) -> TranscriptionResult {
        let seconds = usage?.seconds ?? 0
        let duration = seconds.isFinite && seconds > 0 ? seconds : 0
        let cost = usage?.cost.flatMap { amount -> ChatCostBreakdown? in
            guard !amount.isNaN, amount >= 0 else { return nil }
            return ChatCostBreakdown(
                inputTokens: max(0, usage?.inputTokens ?? 0),
                outputTokens: max(0, usage?.outputTokens ?? 0),
                totalCost: amount,
                currency: "USD"
            )
        }
        return TranscriptionResult(
            text: text,
            segments: text.isEmpty ? [] : [TranscriptionSegment(startTime: 0, endTime: duration, text: text)],
            confidence: nil,
            duration: duration,
            modelIdentifier: model,
            cost: cost,
            rawPayload: nil,
            debugInfo: nil
        )
    }
}
