import Foundation

/// Token usage OpenAI reports on `response.done`.
public struct OpenAIRealtimeSpeechUsage: Equatable, Sendable {
    public var inputTextTokens = 0
    public var cachedInputTokens = 0
    public var outputTextTokens = 0
    public var outputAudioTokens = 0
    /// False once any response arrives without usage, so its cost is unknown.
    public var isComplete = true

    public init() {}

    /// Text $0.60 / cached $0.06 / text out $2.40 / audio out $20 per million
    /// tokens (model page, read 2026-11-02).
    public var cost: Decimal? {
        guard isComplete else { return nil }
        let uncached = max(inputTextTokens - cachedInputTokens, 0)
        let microDollars = Decimal(uncached) * Decimal(string: "0.6")!
            + Decimal(cachedInputTokens) * Decimal(string: "0.06")!
            + Decimal(outputTextTokens) * Decimal(string: "2.4")!
            + Decimal(outputAudioTokens) * 20
        return microDollars / 1_000_000
    }

    mutating func add(_ object: [String: Any]?) {
        guard let object else {
            isComplete = false
            return
        }
        let input = object["input_token_details"] as? [String: Any]
        let output = object["output_token_details"] as? [String: Any]
        inputTextTokens += input?["text_tokens"] as? Int ?? 0
        cachedInputTokens += input?["cached_tokens"] as? Int ?? 0
        outputTextTokens += output?["text_tokens"] as? Int ?? 0
        outputAudioTokens += output?["audio_tokens"] as? Int ?? 0
    }
}
