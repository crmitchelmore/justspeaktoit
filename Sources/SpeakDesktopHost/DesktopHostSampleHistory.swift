import Foundation
import SpeakCore
import SpeakDesktop

/// Sample History for the screenshot tour (`--ui-screenshots`), written into
/// a throwaway data directory before the controller starts. The transcripts
/// are the ones the Mac's own website screenshots show.
package enum DesktopHostSampleHistory {
    package struct Sample: Sendable {
        let minutesAgo: Double
        let model: String
        let text: String?
        let processed: String?
        let postProcessingModel: String?
        let duration: TimeInterval
        let cost: Decimal?
        let failure: String?
        let profile: String?
    }

    package static let samples: [Sample] = [
        Sample(
            minutesAgo: 18, model: "local/whisperkit/small",
            text: "Could we move the catch-up to Friday? That gives us a little more time to get the first "
                + "version ready.",
            processed: nil, postProcessingModel: nil, duration: 24, cost: nil, failure: nil, profile: nil
        ),
        Sample(
            minutesAgo: 78, model: "deepgram/nova-3",
            text: "the idea for the opening paragraph came to me on the walk home start with the question "
                + "then give one clear example",
            processed: "The idea for the opening paragraph came to me on the walk home. Start with the question, then "
                + "give one clear example.",
            postProcessingModel: "openai/gpt-5-mini", duration: 27, cost: Decimal(string: "0.0021"), failure: nil,
            profile: "Writing"
        ),
        Sample(
            minutesAgo: 138, model: "openai/gpt-4o-transcribe",
            text: "Remind me to send the invoice to Priya before the end of the month, and attach the signed copy.",
            processed: nil, postProcessingModel: nil, duration: 30, cost: Decimal(string: "0.0030"), failure: nil,
            profile: nil
        ),
        Sample(
            minutesAgo: 1_460, model: "elevenlabs/scribe_v2",
            text: "Let's keep the release notes short: what changed, why it matters, and how to turn it off.",
            processed: nil, postProcessingModel: nil, duration: 19, cost: Decimal(string: "0.0042"), failure: nil,
            profile: "Email"
        ),
        Sample(
            minutesAgo: 2_900, model: "deepgram/nova-3", text: nil, processed: nil, postProcessingModel: nil,
            duration: 12, cost: nil, failure: "Deepgram rejected the API key (HTTP 401). Save a new key and retry.",
            profile: nil
        )
    ]

    /// Writes every sample into `directory`/History, with a short silent WAV
    /// for each so playback and Open audio behave as for real recordings.
    package static func seed(directory: URL, now: Date = Date()) async throws {
        let history = directory.appendingPathComponent("History")
        let store = try DesktopRecordingStore(directory: history)
        for sample in samples {
            let id = UUID()
            let filename = id.uuidString + ".wav"
            try silentWAV(seconds: min(sample.duration, 1)).write(
                to: history.appendingPathComponent(filename), options: .atomic
            )
            var record = DesktopRecordingStore.Record(
                id: id, audioFilename: filename, modelIdentifier: sample.model,
                createdAt: now.addingTimeInterval(-sample.minutesAgo * 60)
            )
            if let text = sample.text {
                record.result = TranscriptionResult(
                    text: text, segments: [], confidence: nil, duration: sample.duration,
                    modelIdentifier: sample.model,
                    cost: sample.cost.map {
                        ChatCostBreakdown(inputTokens: 0, outputTokens: 0, totalCost: $0, currency: "USD")
                    },
                    rawPayload: nil, debugInfo: nil
                )
            }
            record.processedText = sample.processed
            record.postProcessingModelIdentifier = sample.postProcessingModel
            record.failure = sample.failure
            record.profileName = sample.profile
            try await store.save(record)
        }
    }

    /// A 16 kHz mono PCM16 WAV of silence.
    static func silentWAV(seconds: TimeInterval) -> Data {
        let samples = Int(16_000 * seconds)
        var data = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16_000))
        append(UInt32(32_000))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(samples * 2))
        data.append(Data(count: samples * 2))
        return data
    }
}
