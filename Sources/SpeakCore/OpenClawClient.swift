import Foundation
import os.log

// MARK: - OpenClaw Gateway WebSocket Client

/// A lightweight client for the OpenClaw gateway WebSocket protocol.
/// Supports chat.send, chat.history, and streaming chat events.
public final class OpenClawClient: @unchecked Sendable {
    // MARK: - Types

    public struct ConnectConfig: Codable, Sendable {
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

    public enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    public struct ChatMessage: Identifiable, Codable, Sendable {
        public let id: String
        public let role: String // "user" or "assistant"
        public let content: String
        public let timestamp: Date

        public init(id: String = UUID().uuidString, role: String, content: String, timestamp: Date = Date()) {
            self.id = id
            self.role = role
            self.content = content
            self.timestamp = timestamp
        }
    }

    public struct Conversation: Identifiable, Codable, Sendable {
        public let id: String
        public var sessionKey: String
        public var title: String
        public var messages: [ChatMessage]
        public var createdAt: Date
        public var updatedAt: Date

        public init(
            id: String = UUID().uuidString,
            sessionKey: String,
            title: String = "New Conversation",
            messages: [ChatMessage] = [],
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

    // MARK: - Protocol Frames

    private struct RequestFrame: Encodable {
        let id: String
        let method: String
        let params: [String: AnyCodable]?
    }

    private struct ConnectFrame: Encodable {
        let id: String
        let method: String = "connect"
        let params: ConnectParams

        struct ConnectParams: Encodable {
            let token: String
            let clientName: String
            let mode: String
            let protocolVersion: Int

            enum CodingKeys: String, CodingKey {
                case token
                case clientName
                case mode
                case protocolVersion = "protocol"
            }
        }
    }

    private struct ResponseFrame: Decodable {
        let id: String?
        let result: AnyCodable?
        let error: ResponseError?

        struct ResponseError: Decodable {
            let message: String
            let code: String?
        }
    }

    private struct EventFrame: Decodable {
        let event: String
        let data: AnyCodable?
    }

    private struct IncomingFrame: Decodable {
        // Response fields
        let id: String?
        let result: AnyCodable?
        let error: ResponseFrame.ResponseError?
        // Event fields
        let event: String?
        let data: AnyCodable?
    }

    // MARK: - Properties

    private var webSocket: URLSessionWebSocketTask?
    private let session: URLSession
    private var config: ConnectConfig?
    private var pendingRequests: [String: (Result<AnyCodable?, Error>) -> Void] = [:]
    private let logger = Logger(subsystem: "com.justspeaktoit.ios", category: "OpenClawClient")
    private var requestCounter = 0
    private var isConnected = false
    private var reconnectTimer: Timer?

    // Callbacks
    public var onConnectionStateChanged: ((ConnectionState) -> Void)?
    public var onChatDelta: ((String, String) -> Void)? // (runId, deltaText)
    public var onChatFinal: ((String, String) -> Void)? // (runId, finalMessage)
    public var onChatError: ((String, String) -> Void)? // (runId, errorMessage)

    // MARK: - Init

    public init() {
        self.session = URLSession(configuration: .default)
    }

    // MARK: - Connection

    public func connect(config: ConnectConfig) {
        self.config = config
        onConnectionStateChanged?(.connecting)

        guard let url = URL(string: config.gatewayURL) else {
            onConnectionStateChanged?(.error("Invalid gateway URL"))
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        webSocket = session.webSocketTask(with: request)
        webSocket?.resume()

        logger.info("Connecting to OpenClaw gateway at \(config.gatewayURL)")

        // Send connect frame
        let connectFrame = ConnectFrame(
            id: nextRequestId(),
            params: .init(
                token: config.token,
                clientName: config.clientName,
                mode: "chat",
                protocolVersion: 1
            )
        )

        sendFrame(connectFrame) { [weak self] result in
            switch result {
            case .success:
                self?.isConnected = true
                self?.onConnectionStateChanged?(.connected)
                self?.logger.info("Connected to OpenClaw gateway")
            case .failure(let error):
                self?.isConnected = false
                self?.onConnectionStateChanged?(.error(error.localizedDescription))
                self?.logger.error("Connection failed: \(error.localizedDescription)")
            }
        }

        receiveMessages()
    }

    public func disconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        isConnected = false
        onConnectionStateChanged?(.disconnected)
    }

    // MARK: - Chat API

    /// Send a message to the OpenClaw agent and receive streaming responses.
    public func sendMessage(
        _ message: String,
        sessionKey: String? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let key = sessionKey ?? config?.sessionKey ?? "speak-ios:voice"
        let idempotencyKey = UUID().uuidString
        let reqId = nextRequestId()

        let params: [String: AnyCodable] = [
            "sessionKey": AnyCodable(key),
            "message": AnyCodable(message),
            "idempotencyKey": AnyCodable(idempotencyKey),
        ]

        let frame = RequestFrame(id: reqId, method: "chat.send", params: params)

        sendFrame(frame) { result in
            switch result {
            case .success(let value):
                // chat.send returns { runId: string }
                if let dict = value?.value as? [String: Any],
                   let runId = dict["runId"] as? String {
                    completion(.success(runId))
                } else {
                    completion(.success(""))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// Fetch chat history for a session.
    public func fetchHistory(
        sessionKey: String? = nil,
        limit: Int = 50,
        completion: @escaping (Result<[ChatMessage], Error>) -> Void
    ) {
        let key = sessionKey ?? config?.sessionKey ?? "speak-ios:voice"
        let reqId = nextRequestId()

        let params: [String: AnyCodable] = [
            "sessionKey": AnyCodable(key),
            "limit": AnyCodable(limit),
        ]

        let frame = RequestFrame(id: reqId, method: "chat.history", params: params)

        sendFrame(frame) { result in
            switch result {
            case .success(let value):
                let messages = Self.parseHistoryResponse(value)
                completion(.success(messages))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Private

    private func nextRequestId() -> String {
        requestCounter += 1
        return "req-\(requestCounter)"
    }

    private func sendFrame<T: Encodable>(_ frame: T, completion: ((Result<AnyCodable?, Error>) -> Void)? = nil) {
        do {
            let data = try JSONEncoder().encode(frame)
            guard let text = String(data: data, encoding: .utf8) else {
                completion?(.failure(OpenClawError.encodingFailed))
                return
            }

            // Extract ID for pending tracking
            if let completion, let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = dict["id"] as? String {
                pendingRequests[id] = completion
            }

            webSocket?.send(.string(text)) { [weak self] error in
                if let error {
                    self?.logger.error("Send failed: \(error.localizedDescription)")
                    completion?(.failure(error))
                }
            }
        } catch {
            logger.error("Encoding failed: \(error.localizedDescription)")
            completion?(.failure(error))
        }
    }

    private func receiveMessages() {
        webSocket?.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleIncomingMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleIncomingMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessages()

            case .failure(let error):
                self.logger.error("WebSocket receive error: \(error.localizedDescription)")
                self.isConnected = false
                self.onConnectionStateChanged?(.error(error.localizedDescription))
            }
        }
    }

    private func handleIncomingMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        do {
            let frame = try JSONDecoder().decode(IncomingFrame.self, from: data)

            // Response to a request
            if let id = frame.id {
                if let error = frame.error {
                    let err = OpenClawError.serverError(error.message)
                    pendingRequests[id]?(.failure(err))
                } else {
                    pendingRequests[id]?(.success(frame.result))
                }
                pendingRequests.removeValue(forKey: id)
                return
            }

            // Event
            if let event = frame.event {
                handleEvent(event, data: frame.data)
            }
        } catch {
            logger.debug("Failed to parse incoming frame: \(error.localizedDescription)")
        }
    }

    private func handleEvent(_ event: String, data: AnyCodable?) {
        guard event == "chat" else { return }

        guard let dict = data?.value as? [String: Any],
              let runId = dict["runId"] as? String,
              let state = dict["state"] as? String else {
            return
        }

        switch state {
        case "delta":
            if let message = dict["message"] as? [String: Any],
               let content = message["content"] as? String {
                onChatDelta?(runId, content)
            }
        case "final":
            if let message = dict["message"] as? [String: Any],
               let content = message["content"] as? String {
                onChatFinal?(runId, content)
            } else {
                onChatFinal?(runId, "")
            }
        case "error":
            let errorMessage = dict["errorMessage"] as? String ?? "Unknown error"
            onChatError?(runId, errorMessage)
        case "aborted":
            onChatError?(runId, "Response was aborted")
        default:
            break
        }
    }

    private static func parseHistoryResponse(_ value: AnyCodable?) -> [ChatMessage] {
        guard let dict = value?.value as? [String: Any],
              let entries = dict["messages"] as? [[String: Any]] else {
            return []
        }

        return entries.compactMap { entry in
            guard let role = entry["role"] as? String,
                  let content = entry["content"] as? String else {
                return nil
            }
            let id = entry["id"] as? String ?? UUID().uuidString
            return ChatMessage(
                id: id,
                role: role,
                content: content,
                timestamp: Date()
            )
        }
    }
}

// MARK: - Error

public enum OpenClawError: LocalizedError {
    case encodingFailed
    case serverError(String)
    case notConnected
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode request"
        case .serverError(let message):
            return "Server error: \(message)"
        case .notConnected:
            return "Not connected to OpenClaw gateway"
        case .invalidResponse:
            return "Invalid response from server"
        }
    }
}

// MARK: - AnyCodable helper

public struct AnyCodable: Codable, Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported type"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            let context = EncodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Unsupported type: \(type(of: value))"
            )
            throw EncodingError.invalidValue(value, context)
        }
    }
}
