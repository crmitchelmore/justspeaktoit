import Foundation

public enum ApplicationHistoryItemSource: String, Codable, Hashable, Sendable {
    case importedFile
}

public struct ApplicationHistoryItem: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let updatedAt: Date
    public let modelsUsed: [String]
    public let modelUsages: [ApplicationModelUsage]
    public let rawTranscription: String?
    public let postProcessedTranscription: String?
    public let recordingDuration: TimeInterval
    public let cost: ApplicationHistoryCost?
    public let audioFileURL: URL?
    public let networkExchanges: [ApplicationHistoryNetworkExchange]
    public let events: [ApplicationHistoryEvent]
    public let phaseTimestamps: ApplicationPhaseTimestamps
    public let trigger: ApplicationHistoryTrigger
    public let personalCorrections: PersonalLexiconHistorySummary?
    public let errors: [ApplicationHistoryError]
    public let source: ApplicationHistoryItemSource?
    public let postProcessingPrompt: ApplicationPostProcessingPromptPayload?
    public let diagnosticContext: ApplicationHistoryDiagnosticContext?
    public let latency: SessionLatencyMetrics?

    public init(
        id: UUID = UUID(), createdAt: Date = Date(), updatedAt: Date = Date(), modelsUsed: [String],
        modelUsages: [ApplicationModelUsage] = [],
        rawTranscription: String?, postProcessedTranscription: String?, recordingDuration: TimeInterval,
        cost: ApplicationHistoryCost?, audioFileURL: URL?, networkExchanges: [ApplicationHistoryNetworkExchange],
        events: [ApplicationHistoryEvent], phaseTimestamps: ApplicationPhaseTimestamps,
        trigger: ApplicationHistoryTrigger,
        personalCorrections: PersonalLexiconHistorySummary?, errors: [ApplicationHistoryError],
        source: ApplicationHistoryItemSource? = nil,
        postProcessingPrompt: ApplicationPostProcessingPromptPayload? = nil,
        diagnosticContext: ApplicationHistoryDiagnosticContext? = nil,
        latency: SessionLatencyMetrics? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.modelsUsed = modelsUsed
        self.modelUsages = modelUsages
        self.rawTranscription = rawTranscription
        self.postProcessedTranscription = postProcessedTranscription
        self.recordingDuration = recordingDuration
        self.cost = cost
        self.audioFileURL = audioFileURL
        self.networkExchanges = networkExchanges
        self.events = events
        self.phaseTimestamps = phaseTimestamps
        self.trigger = trigger
        self.personalCorrections = personalCorrections
        self.errors = errors
        self.source = source
        self.postProcessingPrompt = postProcessingPrompt
        self.diagnosticContext = diagnosticContext
        self.latency = latency
    }
}
