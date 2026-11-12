import Foundation

extension TranscriptionResult {
    /// A batch provider's result: its timed segments, or one segment spanning
    /// the whole recording when the provider returned none.
    static func batch(
        text: String, segments: [TranscriptionSegment], confidence: Double? = nil,
        duration: TimeInterval, model: String, payload: Data?
    ) -> TranscriptionResult {
        TranscriptionResult(
            text: text,
            segments: segments.isEmpty ? [TranscriptionSegment(startTime: 0, endTime: duration, text: text)] : segments,
            confidence: confidence,
            duration: duration,
            modelIdentifier: model,
            cost: nil,
            rawPayload: payload.flatMap { String(data: $0, encoding: .utf8) },
            debugInfo: nil
        )
    }
}
