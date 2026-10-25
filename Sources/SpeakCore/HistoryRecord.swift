import Foundation

/// Immutable local history value. Existing stores keep encoding their platform adapters.
/// Local URLs, diagnostics and network payloads are not a cross-device disclosure policy.
public struct HistoryRecord: Codable, Identifiable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
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
    public let phaseTimestamps: ApplicationPhaseTimestamps?
    public let trigger: ApplicationHistoryTrigger?
    public let personalCorrections: PersonalLexiconHistorySummary?
    public let errors: [ApplicationHistoryError]
    public let source: ApplicationHistoryItemSource?
    public let postProcessingPrompt: ApplicationPostProcessingPromptPayload?
    public let diagnosticContext: ApplicationHistoryDiagnosticContext?
    public let latency: SessionLatencyMetrics?
    public let desktopHistory: AnyCodable?
    public let model: String?
    public let wordCount: Int?
    public let originPlatform: String
    public let errorMessage: String?

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
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
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
        self.desktopHistory = desktopHistory
        self.model = model
        self.wordCount = wordCount
        self.originPlatform = originPlatform
        self.errorMessage = errorMessage
    }

    /// Native records keep their original platform's presentation choices.
    public var presentation: HistoryPresentationItem {
        if self.model != nil { return self.iosPresentation }
        return self.makePresentation(
            raw: self.rawTranscription,
            models: self.modelUsages.isEmpty ? self.modelsUsed : self.modelUsages.map(\.modelIdentifier),
            cost: self.cost?.total ?? 0, errors: self.errors.count
        )
    }

    /// An iOS display adapter may retain a richer source without adopting its
    /// multi-model/cost/capture-error presentation. Local errors remain filterable.
    public var iosPresentation: HistoryPresentationItem {
        self.makePresentation(
            raw: self.rawTranscription ?? "",
            models: [self.model ?? self.modelUsages.first?.modelIdentifier ?? self.modelsUsed.first ?? ""],
            cost: 0, errors: self.errorMessage == nil ? 0 : 1
        )
    }

    private func makePresentation(
        raw: String?, models: [String], cost: Decimal, errors: Int
    ) -> HistoryPresentationItem {
        HistoryPresentationItem(
            id: self.id, createdAt: self.createdAt,
            rawTranscription: raw, processedTranscription: self.postProcessedTranscription,
            modelIdentifiers: models, recordingDuration: self.recordingDuration,
            cost: cost, errorCount: errors, originPlatform: self.originPlatform
        )
    }

    public var bestText: String? { self.postProcessedTranscription ?? self.rawTranscription }
    public var hasPolishedText: Bool { !(self.postProcessedTranscription ?? "").isEmpty }

    /// Editing the iOS-visible fields preserves every retained local diagnostic.
    public func replacingLocalText(
        postProcessedTranscription: String?, errorMessage: String?, updatedAt: Date
    ) -> Self {
        Self(
            id: self.id,
            createdAt: self.createdAt,
            updatedAt: updatedAt,
            modelsUsed: self.modelsUsed,
            modelUsages: self.modelUsages,
            rawTranscription: self.rawTranscription,
            postProcessedTranscription: postProcessedTranscription,
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
            desktopHistory: self.desktopHistory,
            model: self.model,
            wordCount: self.wordCount,
            originPlatform: self.originPlatform,
            errorMessage: errorMessage
        )
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case createdAt
        case updatedAt
        case modelsUsed
        case modelUsages
        case rawTranscription
        case postProcessedTranscription
        case recordingDuration
        case cost
        case audioFileURL
        case networkExchanges
        case events
        case phaseTimestamps
        case trigger
        case personalCorrections
        case errors
        case source
        case postProcessingPrompt
        case diagnosticContext
        case latency
        case desktopHistory
        case model
        case wordCount
        case originPlatform
        case errorMessage
    }
}
