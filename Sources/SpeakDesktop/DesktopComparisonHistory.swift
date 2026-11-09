import Foundation
import SpeakCore

/// Desktop History records for a finished comparison round, one per model
/// lane, built from the shared `ModelComparisonHistory` items so every
/// platform tags and fills comparison results the same way.
///
/// A lane has no audio of its own (the round's single sample stays with the
/// comparison), so records carry no audio file: playback and retry report the
/// missing audio instead of touching the comparison sample. `originPlatform`
/// stays nil because these are local results, not synced copies.
public enum DesktopComparisonHistory {
    public static func records(
        for round: ModelComparisonRound, savedAt: Date = Date()
    ) -> [DesktopRecordingStore.Record] {
        // `items(for:)` yields one item per entry, in blind order.
        let items = ModelComparisonHistory.items(for: round, savedAt: savedAt)
        return zip(round.entriesInBlindOrder, items).map { entry, item in
            let model = item.modelsUsed.first ?? "comparison/unknown"
            var record = DesktopRecordingStore.Record(
                id: item.id, audioFilename: "", modelIdentifier: model, createdAt: item.createdAt
            )
            record.recordedDuration = item.recordingDuration
            record.importedCost = item.cost
            if let text = item.rawTranscription {
                record.result = TranscriptionResult(
                    text: text, segments: [], confidence: nil, duration: item.recordingDuration,
                    modelIdentifier: model,
                    cost: item.cost.map {
                        ChatCostBreakdown(inputTokens: 0, outputTokens: 0, totalCost: $0.total, currency: $0.currency)
                    },
                    rawPayload: nil, debugInfo: nil
                )
            }
            record.failure = item.errors.first?.message
            record.profileName = ModelComparisonHistory.triggerDescription
            record.profileNotes = notes(for: entry, round: round)
            return record
        }
    }

    public static func isComparisonRecord(_ record: DesktopRecordingStore.Record) -> Bool {
        record.profileName == ModelComparisonHistory.triggerDescription && record.audioFilename.isEmpty
            && !record.isSyncedCopy
    }

    static func notes(for entry: ModelComparisonEntry, round: ModelComparisonRound) -> [String] {
        var notes = ["\(round.inputMode.displayName) comparison round \(round.id.uuidString)"]
        if round.inputMode == .streaming {
            if let first = entry.timeToFirstPartialMs { notes.append("First partial: \(first) ms") }
            if let final = entry.timeToFinalMs { notes.append("Stop to final: \(final) ms") }
        } else if let request = entry.timeToFinalMs {
            notes.append("Request: \(request) ms")
        }
        return notes
    }
}
