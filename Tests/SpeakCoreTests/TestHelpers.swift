import Foundation
@testable import SpeakCore

// MARK: - TranscriptionSegment factory

extension TranscriptionSegment {
    static func stub(
        text: String = "hello",
        startTime: TimeInterval = 0.0,
        endTime: TimeInterval = 1.0,
        isFinal: Bool = true,
        confidence: Double? = nil
    ) -> TranscriptionSegment {
        TranscriptionSegment(
            startTime: startTime,
            endTime: endTime,
            text: text,
            isFinal: isFinal,
            confidence: confidence
        )
    }
}

// MARK: - ChatCostBreakdown factory

extension ChatCostBreakdown {
    static func stub(
        inputTokens: Int = 100,
        outputTokens: Int = 50,
        totalCost: Decimal = 0.001,
        currency: String = "USD"
    ) -> ChatCostBreakdown {
        ChatCostBreakdown(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalCost: totalCost,
            currency: currency
        )
    }
}

// MARK: - TranscriptionResult factory

extension TranscriptionResult {
    static func stub(
        text: String = "hello world",
        segments: [TranscriptionSegment] = [],
        confidence: Double? = nil,
        duration: TimeInterval = 1.5,
        modelIdentifier: String = "test-model",
        cost: ChatCostBreakdown? = nil,
        rawPayload: String? = nil,
        debugInfo: TranscriptionDebugInfo? = nil
    ) -> TranscriptionResult {
        TranscriptionResult(
            text: text,
            segments: segments,
            confidence: confidence,
            duration: duration,
            modelIdentifier: modelIdentifier,
            cost: cost,
            rawPayload: rawPayload,
            debugInfo: debugInfo
        )
    }
}

// MARK: - OpenClawChatMessage factory

extension OpenClawChatMessage {
    static func stub(
        role: String = "user",
        content: String = "test message",
        timestamp: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> OpenClawChatMessage {
        OpenClawChatMessage(role: role, content: content, timestamp: timestamp)
    }
}

// MARK: - OpenClawConversation factory

extension OpenClawConversation {
    static func stub(
        sessionKey: String = "test-session",
        title: String = "Test Conversation",
        messages: [OpenClawChatMessage] = []
    ) -> OpenClawConversation {
        OpenClawConversation(
            sessionKey: sessionKey,
            title: title,
            messages: messages,
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_000_000)
        )
    }
}
