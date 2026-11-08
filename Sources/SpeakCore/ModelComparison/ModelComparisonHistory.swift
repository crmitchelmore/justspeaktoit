import Foundation

/// Turns a finished comparison round into ordinary History items, one per
/// model lane, when the user opts in ("Save results to History").
///
/// The items use the existing History schema unchanged, so older clients and
/// History sync read them as usual. A comparison run is tagged through the
/// trigger (`uiButton`, description ``triggerDescription``, no output), and
/// each item carries that lane's model, raw transcript, estimated cost,
/// latency and, for a failed lane, its error.
public enum ModelComparisonHistory {
    /// The trigger description that marks a History item as a comparison run.
    public static let triggerDescription = "Compare Models"

    public static func isComparisonItem(_ item: ApplicationHistoryItem) -> Bool {
        item.trigger.gesture == .uiButton && item.trigger.hotKeyDescription == triggerDescription
    }

    public static func items(for round: ModelComparisonRound, savedAt: Date = Date()) -> [ApplicationHistoryItem] {
        round.entriesInBlindOrder.map { item(for: $0, in: round, savedAt: savedAt) }
    }

    static func item(
        for entry: ModelComparisonEntry, in round: ModelComparisonRound, savedAt: Date
    ) -> ApplicationHistoryItem {
        let phase: ApplicationModelUsagePhase = round.inputMode == .streaming ? .transcriptionLive : .transcriptionBatch
        let transcript = entry.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = "\(triggerDescription) · \(round.inputMode.displayName) round \(round.id.uuidString) · "
            + "\(entry.modelDisplayName) (\(entry.providerDisplayName))"
        var events = [ApplicationHistoryEvent(kind: .transcriptionSubmitted, timestamp: round.createdAt,
                                              description: summary)]
        var errors: [ApplicationHistoryError] = []
        if let error = entry.errorDescription {
            events.append(ApplicationHistoryEvent(kind: .error, timestamp: savedAt, description: error))
            errors.append(ApplicationHistoryError(phase: .transcription, message: error, occurredAt: savedAt))
        } else {
            events.append(ApplicationHistoryEvent(kind: .transcriptionReceived, timestamp: savedAt,
                                                  description: summary))
        }
        // File rounds time the whole request, not Stop to final, so only a
        // streaming lane's timings map onto History's live latency fields.
        let latency = round.inputMode == .streaming
            ? SessionLatencyMetrics(firstPartialMs: entry.timeToFirstPartialMs, stopToFinalMs: entry.timeToFinalMs)
            : SessionLatencyMetrics()
        return ApplicationHistoryItem(
            createdAt: round.createdAt,
            updatedAt: savedAt,
            modelsUsed: [entry.modelID],
            modelUsages: [ApplicationModelUsage(modelIdentifier: entry.modelID, phase: phase)],
            rawTranscription: transcript.isEmpty ? nil : transcript,
            postProcessedTranscription: nil,
            recordingDuration: round.sample.durationSeconds,
            cost: entry.estimatedCostUSD.map { ApplicationHistoryCost(total: $0, currency: "USD") },
            audioFileURL: nil,
            networkExchanges: [],
            events: events,
            phaseTimestamps: ApplicationPhaseTimestamps(transcriptionStarted: round.createdAt,
                                                        transcriptionEnded: savedAt),
            trigger: ApplicationHistoryTrigger(gesture: .uiButton, hotKeyDescription: triggerDescription,
                                               outputMethod: .none),
            personalCorrections: nil,
            errors: errors,
            latency: latency.hasAnyInterval ? latency : nil
        )
    }
}
