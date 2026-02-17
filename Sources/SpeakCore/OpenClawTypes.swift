import Foundation

// MARK: - OpenClaw Client Types

/// Configuration for connecting to an OpenClaw gateway.
public struct OpenClawConnectConfig: Codable, Sendable {
    public var gatewayURL: String // ws://host:port or wss://host:port
    public var token: String
    public var clientName: String
    public var sessionKey: String

    public init(
        gatewayURL: String,
        token: String,
        clientName: String = "speak-ios",
        sessionKey: String = "speak-ios:voice"
    ) {
        self.gatewayURL = gatewayURL
        self.token = token
        self.clientName = clientName
        self.sessionKey = sessionKey
    }
}

/// WebSocket connection state for the OpenClaw gateway.
public enum OpenClawConnectionState: Sendable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

/// A single chat message exchanged with the gateway.
public struct OpenClawChatMessage: Identifiable, Codable, Sendable {
    public let id: String
    public let role: String // "user" or "assistant"
    public let content: String
    public let timestamp: Date

    public init(
        id: String = UUID().uuidString,
        role: String,
        content: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

/// A conversation backed by an OpenClaw gateway session.
public struct OpenClawConversation: Identifiable, Codable, Sendable {
    public let id: String
    public var sessionKey: String
    public var title: String
    public var messages: [OpenClawChatMessage]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        sessionKey: String,
        title: String = "New Conversation",
        messages: [OpenClawChatMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sessionKey = sessionKey
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
