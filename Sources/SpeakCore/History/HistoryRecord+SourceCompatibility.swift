import Foundation

/// The initialiser signatures HistoryRecord published before it gained
/// `requestContext` and `requestFailure`. They stay for API compatibility only:
/// the designated initialiser now defaults both, so every call resolves to it.
extension HistoryRecord {
    @_disfavoredOverload
    @available(*, deprecated, message: "Use the initialiser that takes requestFailure.")
    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        modelsUsed: [String] = [],
        modelUsages: [ApplicationModelUsage] = [],
        rawTranscription: String? = nil,
        postProcessedTranscription: String? = nil,
        recordingDuration: TimeInterval,
        cost: ApplicationHistoryCost? = nil,
        audioFileURL: URL? = nil,
        networkExchanges: [ApplicationHistoryNetworkExchange] = [],
        events: [ApplicationHistoryEvent] = [],
        phaseTimestamps: ApplicationPhaseTimestamps? = nil,
        trigger: ApplicationHistoryTrigger? = nil,
        personalCorrections: PersonalLexiconHistorySummary? = nil,
        errors: [ApplicationHistoryError] = [],
        source: ApplicationHistoryItemSource? = nil,
        postProcessingPrompt: ApplicationPostProcessingPromptPayload? = nil,
        diagnosticContext: ApplicationHistoryDiagnosticContext? = nil,
        latency: SessionLatencyMetrics? = nil,
        desktopHistory: AnyCodable? = nil,
        model: String? = nil,
        wordCount: Int? = nil,
        originPlatform: String = "macos",
        errorMessage: String? = nil
    ) {
        self.init(
            id: id, createdAt: createdAt, updatedAt: updatedAt, modelsUsed: modelsUsed, modelUsages: modelUsages,
            rawTranscription: rawTranscription, postProcessedTranscription: postProcessedTranscription,
            recordingDuration: recordingDuration, cost: cost, audioFileURL: audioFileURL,
            networkExchanges: networkExchanges, events: events, phaseTimestamps: phaseTimestamps,
            trigger: trigger, personalCorrections: personalCorrections, errors: errors, source: source,
            postProcessingPrompt: postProcessingPrompt, diagnosticContext: diagnosticContext, latency: latency,
            desktopHistory: desktopHistory, model: model, wordCount: wordCount, originPlatform: originPlatform,
            errorMessage: errorMessage, requestContext: nil, requestFailure: nil
        )
    }

    @_disfavoredOverload
    @available(*, deprecated, message: "Use the initialiser that takes requestFailure.")
    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        modelsUsed: [String] = [],
        modelUsages: [ApplicationModelUsage] = [],
        rawTranscription: String? = nil,
        postProcessedTranscription: String? = nil,
        recordingDuration: TimeInterval,
        cost: ApplicationHistoryCost? = nil,
        audioFileURL: URL? = nil,
        networkExchanges: [ApplicationHistoryNetworkExchange] = [],
        events: [ApplicationHistoryEvent] = [],
        phaseTimestamps: ApplicationPhaseTimestamps? = nil,
        trigger: ApplicationHistoryTrigger? = nil,
        personalCorrections: PersonalLexiconHistorySummary? = nil,
        errors: [ApplicationHistoryError] = [],
        source: ApplicationHistoryItemSource? = nil,
        postProcessingPrompt: ApplicationPostProcessingPromptPayload? = nil,
        diagnosticContext: ApplicationHistoryDiagnosticContext? = nil,
        latency: SessionLatencyMetrics? = nil,
        desktopHistory: AnyCodable? = nil,
        model: String? = nil,
        wordCount: Int? = nil,
        originPlatform: String = "macos",
        errorMessage: String? = nil,
        requestContext: RequestDiagnosticContext?
    ) {
        self.init(
            id: id, createdAt: createdAt, updatedAt: updatedAt, modelsUsed: modelsUsed, modelUsages: modelUsages,
            rawTranscription: rawTranscription, postProcessedTranscription: postProcessedTranscription,
            recordingDuration: recordingDuration, cost: cost, audioFileURL: audioFileURL,
            networkExchanges: networkExchanges, events: events, phaseTimestamps: phaseTimestamps,
            trigger: trigger, personalCorrections: personalCorrections, errors: errors, source: source,
            postProcessingPrompt: postProcessingPrompt, diagnosticContext: diagnosticContext, latency: latency,
            desktopHistory: desktopHistory, model: model, wordCount: wordCount, originPlatform: originPlatform,
            errorMessage: errorMessage, requestContext: requestContext, requestFailure: nil
        )
    }
}
