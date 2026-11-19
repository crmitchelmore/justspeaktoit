import Foundation

public struct ApplicationHistoryEvent: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case recordingStarted, recordingStopped, transcriptionSubmitted, transcriptionReceived
        case postProcessingSubmitted, postProcessingReceived, outputDelivered, error
    }

    public let id: UUID
    public let kind: Kind
    public let timestamp: Date
    public let description: String

    public init(id: UUID = UUID(), kind: Kind, timestamp: Date = Date(), description: String) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.description = description
    }
}

public struct ApplicationHistoryNetworkExchange: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let method: String
    public let requestHeaders: [String: String]
    public let requestBodyPreview: String
    public let responseCode: Int
    public let responseHeaders: [String: String]
    public let responseBodyPreview: String

    public init(
        id: UUID = UUID(), url: URL, method: String, requestHeaders: [String: String],
        requestBodyPreview: String, responseCode: Int, responseHeaders: [String: String],
        responseBodyPreview: String
    ) {
        self.id = id
        self.url = url
        self.method = method
        self.requestHeaders = requestHeaders
        self.requestBodyPreview = requestBodyPreview
        self.responseCode = responseCode
        self.responseHeaders = responseHeaders
        self.responseBodyPreview = responseBodyPreview
    }
}

public struct ApplicationHistoryError: Codable, Identifiable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case recording, transcription, postProcessing, output, storage
    }

    public let id: UUID
    public let phase: Phase
    public let message: String
    public let debugDescription: String?
    public let occurredAt: Date

    public init(
        id: UUID = UUID(), phase: Phase, message: String, debugDescription: String? = nil,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.phase = phase
        self.message = message
        self.debugDescription = debugDescription
        self.occurredAt = occurredAt
    }
}

public struct ApplicationHistoryTrigger: Codable, Hashable, Sendable {
    public enum HotKeyGesture: String, Codable, Sendable {
        case singleTap, doubleTap, hold, uiButton, automation
    }

    public enum OutputMethod: String, Codable, Sendable {
        case accessibility, clipboard, none
    }

    public let gesture: HotKeyGesture
    public let hotKeyDescription: String
    public let outputMethod: OutputMethod
    public let destinationApplication: String?

    public init(
        gesture: HotKeyGesture, hotKeyDescription: String, outputMethod: OutputMethod,
        destinationApplication: String? = nil
    ) {
        self.gesture = gesture
        self.hotKeyDescription = hotKeyDescription
        self.outputMethod = outputMethod
        self.destinationApplication = destinationApplication
    }
}

public struct ApplicationHistoryCost: Codable, Hashable, Sendable {
    public let total: Decimal
    public let currency: String
    public let breakdown: ChatCostBreakdown?

    public init(total: Decimal, currency: String, breakdown: ChatCostBreakdown? = nil) {
        self.total = total
        self.currency = currency
        self.breakdown = breakdown
    }
}

public enum ApplicationModelUsagePhase: String, Codable, Hashable, Sendable {
    case transcriptionLive = "live"
    case transcriptionBatch = "batch"
    case transcriptionLocal = "local"
    case postProcessing = "post-processing"
}

public struct ApplicationModelUsage: Codable, Hashable, Sendable {
    public let modelIdentifier: String
    public let phase: ApplicationModelUsagePhase

    public init(modelIdentifier: String, phase: ApplicationModelUsagePhase) {
        self.modelIdentifier = modelIdentifier
        self.phase = phase
    }
}

public struct ApplicationPostProcessingPromptPayload: Codable, Hashable, Sendable {
    public let modelIdentifier: String
    public let customPrompt: String?
    public let systemPrompt: String
    public let userPrompt: String

    public init(modelIdentifier: String, customPrompt: String? = nil, systemPrompt: String, userPrompt: String) {
        self.modelIdentifier = modelIdentifier
        self.customPrompt = customPrompt
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
    }
}

public struct ApplicationPhaseTimestamps: Codable, Hashable, Sendable {
    public let recordingStarted: Date?
    public let recordingEnded: Date?
    public let transcriptionStarted: Date?
    public let transcriptionEnded: Date?
    public let postProcessingStarted: Date?
    public let postProcessingEnded: Date?
    public let outputDelivered: Date?

    public init(
        recordingStarted: Date? = nil, recordingEnded: Date? = nil,
        transcriptionStarted: Date? = nil, transcriptionEnded: Date? = nil,
        postProcessingStarted: Date? = nil, postProcessingEnded: Date? = nil, outputDelivered: Date? = nil
    ) {
        self.recordingStarted = recordingStarted
        self.recordingEnded = recordingEnded
        self.transcriptionStarted = transcriptionStarted
        self.transcriptionEnded = transcriptionEnded
        self.postProcessingStarted = postProcessingStarted
        self.postProcessingEnded = postProcessingEnded
        self.outputDelivered = outputDelivered
    }

    public var postProcessingDurationMs: Int? {
        guard let start = postProcessingStarted, let end = postProcessingEnded else { return nil }
        return Int(end.timeIntervalSince(start) * 1000)
    }

    public var transcriptionDurationMs: Int? {
        guard let start = transcriptionStarted, let end = transcriptionEnded else { return nil }
        return Int(end.timeIntervalSince(start) * 1000)
    }
}
