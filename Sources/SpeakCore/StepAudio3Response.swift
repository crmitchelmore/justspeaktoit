import Foundation

enum StepAudio3Response {
    private struct Event: Decodable {
        let type: String
        let text: String?
        let delta: String?
        let message: String?
        let startTime: Double?
        let endTime: Double?
    }

    private struct Transcript {
        var text: String?
        var segments: [TranscriptionSegment] = []

        mutating func consume(_ event: Event) throws {
            switch event.type {
            case "error":
                throw FileSpeechError.service(event.message ?? "StepFun returned an error.")
            case "transcript.text.delta":
                guard text == nil, let delta = event.delta else { return }
                if let start = event.startTime, let end = event.endTime {
                    segments.append(TranscriptionSegment(startTime: start / 1_000, endTime: end / 1_000, text: delta))
                }
            case "transcript.text.done":
                guard let final = event.text else { throw TranscriptionProviderError.invalidResponse }
                text = final
            default: break
            }
        }
    }

    static func decode(_ data: Data, captureDuration: TimeInterval) throws -> TranscriptionResult {
        guard captureDuration.isFinite, captureDuration >= 0,
              let source = String(data: data, encoding: .utf8) else {
            throw TranscriptionProviderError.invalidResponse
        }
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var transcript = Transcript()
        for block in normalized.components(separatedBy: "\n\n") {
            try Task.checkCancellation()
            let payload = payload(in: block)
            guard !payload.isEmpty, payload.trimmingCharacters(in: .whitespaces) != "[DONE]" else { continue }
            try transcript.consume(decoder.decode(Event.self, from: Data(payload.utf8)))
        }
        guard let text = transcript.text else { throw FileSpeechError.missingCompletion("StepFun") }
        var segments = transcript.segments
        // Final text can correct the deltas, so stale word timing/text pairs
        // must not survive a correction (including an authoritative silence).
        if segments.map(\.text).joined() != text { segments = [] }
        let duration = captureDuration > 0 ? captureDuration : segments.map(\.endTime).max() ?? 0
        guard duration.isFinite, duration >= 0, duration < Double(Int.max) else {
            throw TranscriptionProviderError.invalidResponse
        }
        let cost = duration > 0 ? ChatCostBreakdown(
            inputTokens: Int(duration), outputTokens: 0,
            totalCost: Decimal(duration) * Decimal(string: "2.8")! / 3_600, currency: "CNY"
        ) : nil
        return TranscriptionResult(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: segments, confidence: nil, duration: duration,
            modelIdentifier: FileSpeechProvider.stepfun.modelID, cost: cost, rawPayload: source, debugInfo: nil
        )
    }

    private static func payload(in block: String) -> String {
        block.components(separatedBy: "\n").compactMap { line -> String? in
            guard line.hasPrefix("data:") else { return nil }
            let value = String(line.dropFirst(5))
            return value.hasPrefix(" ") ? String(value.dropFirst()) : value
        }.joined(separator: "\n")
    }
}
