import Foundation

extension SonioxBatchClient {
    func buildTranscriptionResult(
        transcript: SonioxTranscript,
        transcription: SonioxTranscription,
        model: String
    ) -> TranscriptionResult {
        let segments = self.groupedSegments(from: transcript.tokens)
        let duration = transcription.audioDurationMs.map { TimeInterval($0) / 1000 }
            ?? segments.map(\.endTime).max()
            ?? 0
        return TranscriptionResult(
            text: self.formattedTranscript(from: transcript),
            segments: segments.isEmpty
                ? [TranscriptionSegment(startTime: 0, endTime: duration, text: transcript.text)]
                : segments,
            confidence: nil,
            duration: duration,
            modelIdentifier: model,
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
    }

    private func groupedSegments(from tokens: [SonioxTranscriptToken]) -> [TranscriptionSegment] {
        guard !tokens.isEmpty else { return [] }
        guard self.shouldLabelSpeakers(in: tokens) else {
            return self.groupSingleSpeakerSegments(from: tokens)
        }

        var grouped: [TranscriptionSegment] = []
        var currentSpeaker = self.groupingKey(for: tokens[0])
        var currentText = tokens[0].text
        var startMs = tokens[0].startMs
        var endMs = tokens[0].endMs
        var confidences = [tokens[0].confidence]

        for token in tokens.dropFirst() {
            let speaker = self.groupingKey(for: token)
            if speaker == currentSpeaker {
                currentText += token.text
                endMs = token.endMs
                confidences.append(token.confidence)
            } else {
                grouped.append(
                    self.labelledSegment(
                        speaker: currentSpeaker,
                        text: currentText,
                        startMs: startMs,
                        endMs: endMs,
                        confidences: confidences
                    )
                )
                currentSpeaker = speaker
                currentText = token.text
                startMs = token.startMs
                endMs = token.endMs
                confidences = [token.confidence]
            }
        }
        grouped.append(
            self.labelledSegment(
                speaker: currentSpeaker,
                text: currentText,
                startMs: startMs,
                endMs: endMs,
                confidences: confidences
            )
        )
        return grouped
    }

    private func groupSingleSpeakerSegments(from tokens: [SonioxTranscriptToken]) -> [TranscriptionSegment] {
        var grouped: [TranscriptionSegment] = []
        var currentText = ""
        var startMs = tokens[0].startMs
        var endMs = tokens[0].endMs
        var confidences: [Double] = []

        for token in tokens {
            if currentText.isEmpty {
                startMs = token.startMs
            }
            let gapMs = token.startMs - endMs
            if !currentText.isEmpty, gapMs > 1_500 {
                grouped.append(self.unlabelledSegment(
                    text: currentText,
                    startMs: startMs,
                    endMs: endMs,
                    confidences: confidences
                ))
                currentText.removeAll(keepingCapacity: true)
                startMs = token.startMs
                confidences.removeAll(keepingCapacity: true)
            }
            currentText += token.text
            endMs = token.endMs
            confidences.append(token.confidence)

            if self.endsSingleSpeakerSegment(token.text) {
                grouped.append(self.unlabelledSegment(
                    text: currentText,
                    startMs: startMs,
                    endMs: endMs,
                    confidences: confidences
                ))
                currentText.removeAll(keepingCapacity: true)
                confidences.removeAll(keepingCapacity: true)
            }
        }

        if !currentText.isEmpty {
            grouped.append(self.unlabelledSegment(
                text: currentText,
                startMs: startMs,
                endMs: endMs,
                confidences: confidences
            ))
        }
        return grouped
    }

    private func endsSingleSpeakerSegment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!")
    }

    private func unlabelledSegment(
        text: String,
        startMs: Int,
        endMs: Int,
        confidences: [Double]
    ) -> TranscriptionSegment {
        TranscriptionSegment(
            startTime: TimeInterval(startMs) / 1000,
            endTime: TimeInterval(endMs) / 1000,
            text: text,
            confidence: self.averageConfidence(confidences)
        )
    }

    private func labelledSegment(
        speaker: String,
        text: String,
        startMs: Int,
        endMs: Int,
        confidences: [Double]
    ) -> TranscriptionSegment {
        let prefix = speaker.isEmpty ? "" : "\(speaker): "
        return TranscriptionSegment(
            startTime: TimeInterval(startMs) / 1000,
            endTime: TimeInterval(endMs) / 1000,
            text: prefix + text,
            confidence: self.averageConfidence(confidences)
        )
    }

    private func averageConfidence(_ confidences: [Double]) -> Double? {
        guard !confidences.isEmpty else { return nil }
        return confidences.reduce(0, +) / Double(confidences.count)
    }

    private func formattedTranscript(from transcript: SonioxTranscript) -> String {
        let segments = self.groupedSegments(from: transcript.tokens)
        guard self.shouldLabelSpeakers(in: transcript.tokens), !segments.isEmpty else {
            return transcript.text
        }
        return segments.map(\.text).joined(separator: "\n")
    }

    private func shouldLabelSpeakers(in tokens: [SonioxTranscriptToken]) -> Bool {
        Set(tokens.map { self.groupingKey(for: $0) }).count > 1
    }

    private func groupingKey(for token: SonioxTranscriptToken) -> String {
        let speaker = token.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let language = token.language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if speaker.isEmpty { return language.isEmpty ? "" : "Language \(language)" }
        if language.isEmpty { return "Speaker \(speaker)" }
        return "Speaker \(speaker) [\(language)]"
    }

}

struct SonioxFile: Decodable, Sendable {
    let id: String
}

struct SonioxCreateTranscriptionPayload: Encodable, Sendable {
    let model: String
    let fileID: String
    let languageHints: [String]?
    let enableSpeakerDiarization: Bool
    let enableLanguageIdentification: Bool

    private enum CodingKeys: String, CodingKey {
        case model
        case fileID = "file_id"
        case languageHints = "language_hints"
        case enableSpeakerDiarization = "enable_speaker_diarization"
        case enableLanguageIdentification = "enable_language_identification"
    }
}

struct SonioxTranscription: Decodable, Sendable {
    let id: String
    let status: String
    let audioDurationMs: Int?
    let errorType: String?
    let errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case audioDurationMs = "audio_duration_ms"
        case errorType = "error_type"
        case errorMessage = "error_message"
    }
}

struct SonioxTranscriptToken: Decodable, Sendable {
    let text: String
    let startMs: Int
    let endMs: Int
    let confidence: Double
    let speaker: String?
    let language: String?

    private enum CodingKeys: String, CodingKey {
        case text
        case startMs = "start_ms"
        case endMs = "end_ms"
        case confidence
        case speaker
        case language
    }
}

struct SonioxTranscript: Decodable, Sendable {
    let id: String
    let text: String
    let tokens: [SonioxTranscriptToken]
}
