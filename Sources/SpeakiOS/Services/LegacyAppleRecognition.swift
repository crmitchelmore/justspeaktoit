#if os(iOS)
import Foundation
import Speech
import SpeakCore

/// Value snapshot shared by real Speech callbacks and lifecycle tests.
struct LegacyAppleRecognitionUpdate {
    let text: String
    let isFinal: Bool
    let segments: [TranscriptionSegment]
    let confidence: Double?

    init(text: String, isFinal: Bool, segments: [TranscriptionSegment], confidence: Double?) {
        self.text = text
        self.isFinal = isFinal
        self.segments = segments
        self.confidence = confidence
    }

    init(_ result: SFSpeechRecognitionResult) {
        self.text = result.bestTranscription.formattedString
        self.isFinal = result.isFinal
        self.segments = result.bestTranscription.segments.map { segment in
            TranscriptionSegment(
                startTime: segment.timestamp,
                endTime: segment.timestamp + segment.duration,
                text: segment.substring,
                isFinal: true,
                confidence: Double(segment.confidence)
            )
        }
        self.confidence = self.segments.isEmpty ? nil
            : self.segments.compactMap(\.confidence).reduce(0, +) / Double(self.segments.count)
    }
}

/// Keeps the legacy framework boundary injectable without starting a microphone in tests.
@MainActor
struct LegacyAppleRecognitionTask {
    let endAudio: () -> Void
    let finish: () -> Void
    let cancel: () -> Void
}
#endif
