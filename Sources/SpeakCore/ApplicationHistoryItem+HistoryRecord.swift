import Foundation

public extension ApplicationHistoryItem {
    var historyRecord: HistoryRecord {
        HistoryRecord(
            id: self.id,
            createdAt: self.createdAt,
            updatedAt: self.updatedAt,
            modelsUsed: self.modelsUsed,
            modelUsages: self.modelUsages,
            rawTranscription: self.rawTranscription,
            postProcessedTranscription: self.postProcessedTranscription,
            recordingDuration: self.recordingDuration,
            cost: self.cost,
            audioFileURL: self.audioFileURL,
            networkExchanges: self.networkExchanges,
            events: self.events,
            phaseTimestamps: self.phaseTimestamps,
            trigger: self.trigger,
            personalCorrections: self.personalCorrections,
            errors: self.errors,
            source: self.source,
            postProcessingPrompt: self.postProcessingPrompt,
            diagnosticContext: self.diagnosticContext,
            latency: self.latency,
            desktopHistory: self.desktopHistory
        )
    }

    /// Refuses values the legacy Mac shape cannot represent instead of dropping
    /// iOS-only fields or inventing a trigger/capture timeline.
    init?(historyRecord record: HistoryRecord) {
        guard record.model == nil, record.wordCount == nil, record.errorMessage == nil,
              record.originPlatform == "macos",
              let phaseTimestamps = record.phaseTimestamps, let trigger = record.trigger else { return nil }
        self.init(
            id: record.id,
            createdAt: record.createdAt,
            updatedAt: record.updatedAt,
            modelsUsed: record.modelsUsed,
            modelUsages: record.modelUsages,
            rawTranscription: record.rawTranscription,
            postProcessedTranscription: record.postProcessedTranscription,
            recordingDuration: record.recordingDuration,
            cost: record.cost,
            audioFileURL: record.audioFileURL,
            networkExchanges: record.networkExchanges,
            events: record.events,
            phaseTimestamps: phaseTimestamps,
            trigger: trigger,
            personalCorrections: record.personalCorrections,
            errors: record.errors,
            source: record.source,
            postProcessingPrompt: record.postProcessingPrompt,
            diagnosticContext: record.diagnosticContext,
            latency: record.latency,
            desktopHistory: record.desktopHistory
        )
    }
}
