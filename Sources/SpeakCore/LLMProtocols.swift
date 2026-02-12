import Foundation

// MARK: - Chat types

public struct ChatMessage: Codable, Hashable, Identifiable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
    }

    public let id: UUID
    public let role: Role
    public let content: String

    public init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

public struct ChatCostBreakdown: Codable, Hashable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let totalCost: Decimal
    public let currency: String

    public init(inputTokens: Int, outputTokens: Int, totalCost: Decimal, currency: String) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalCost = totalCost
        self.currency = currency
    }
}

public struct ChatResponse: Codable, Hashable, Sendable {
    public let messages: [ChatMessage]
    public let finishReason: String
    public let cost: ChatCostBreakdown?
    public let rawPayload: String?

    public init(messages: [ChatMessage], finishReason: String, cost: ChatCostBreakdown?, rawPayload: String?) {
        self.messages = messages
        self.finishReason = finishReason
        self.cost = cost
        self.rawPayload = rawPayload
    }
}

// MARK: - Chat protocols

public protocol ChatLLMClient {
    func sendChat(systemPrompt: String?, messages: [ChatMessage], model: String, temperature: Double)
        async throws -> ChatResponse
}

public protocol StreamingChatLLMClient: ChatLLMClient {
    func sendChatStreaming(
        systemPrompt: String?,
        messages: [ChatMessage],
        model: String,
        temperature: Double
    ) -> AsyncThrowingStream<String, Error>
}

// MARK: - Transcription types

public struct TranscriptionSegment: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String
    public let isFinal: Bool
    public let confidence: Double?

    public init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        isFinal: Bool = true,
        confidence: Double? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
    }
}

public struct TranscriptionDebugInfo: Codable, Hashable, Sendable {
    public let endpoint: URL
    public let requestHeaders: [String: String]
    public let requestBodyPreview: String
    public let responseCode: Int
    public let responseHeaders: [String: String]
    public let responseBodyPreview: String

    public init(
        endpoint: URL,
        requestHeaders: [String: String],
        requestBodyPreview: String,
        responseCode: Int,
        responseHeaders: [String: String],
        responseBodyPreview: String
    ) {
        self.endpoint = endpoint
        self.requestHeaders = requestHeaders
        self.requestBodyPreview = requestBodyPreview
        self.responseCode = responseCode
        self.responseHeaders = responseHeaders
        self.responseBodyPreview = responseBodyPreview
    }
}

public struct TranscriptionResult: Codable, Hashable, Sendable {
    public let text: String
    public let segments: [TranscriptionSegment]
    public let confidence: Double?
    public let duration: TimeInterval
    public let modelIdentifier: String
    public let cost: ChatCostBreakdown?
    public let rawPayload: String?
    public let debugInfo: TranscriptionDebugInfo?

    public init(
        text: String,
        segments: [TranscriptionSegment],
        confidence: Double?,
        duration: TimeInterval,
        modelIdentifier: String,
        cost: ChatCostBreakdown?,
        rawPayload: String?,
        debugInfo: TranscriptionDebugInfo?
    ) {
        self.text = text
        self.segments = segments
        self.confidence = confidence
        self.duration = duration
        self.modelIdentifier = modelIdentifier
        self.cost = cost
        self.rawPayload = rawPayload
        self.debugInfo = debugInfo
    }
}

// MARK: - Batch transcription protocol

public protocol BatchTranscriptionClient {
    func transcribeFile(at url: URL, model: String, language: String?) async throws
        -> TranscriptionResult
}

// MARK: - Live transcription types and protocols

public struct LiveTranscriptionUpdate: Sendable {
    public let text: String
    public let isFinal: Bool
    public let confidence: Double?

    public init(text: String, isFinal: Bool = false, confidence: Double? = nil) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
    }
}

@MainActor
public protocol LiveTranscriptionSessionDelegate: AnyObject {
    func liveTranscriber(_ session: any LiveTranscriptionController, didUpdatePartial text: String)
    func liveTranscriber(
        _ session: any LiveTranscriptionController,
        didUpdateWith update: LiveTranscriptionUpdate
    )
    func liveTranscriber(
        _ session: any LiveTranscriptionController, didFinishWith result: TranscriptionResult)
    func liveTranscriber(_ session: any LiveTranscriptionController, didFail error: Error)
    func liveTranscriber(
        _ session: any LiveTranscriptionController,
        didDetectUtteranceBoundary utterance: String
    )
}

@MainActor
public protocol LiveTranscriptionController: AnyObject {
    var delegate: LiveTranscriptionSessionDelegate? { get set }
    var isRunning: Bool { get }
    func configure(language: String?, model: String)
    func start() async throws
    func stop() async
}
