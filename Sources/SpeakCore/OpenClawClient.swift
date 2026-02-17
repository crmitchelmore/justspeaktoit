import Foundation
import os.log

// MARK: - OpenClaw Gateway WebSocket Client

/// A lightweight client for the OpenClaw gateway WebSocket protocol (v3).
/// Implements challenge-response handshake, chat.send, chat.history,
/// and streaming chat events.
public final class OpenClawClient: @unchecked Sendable {

    // MARK: - Nested Type Aliases (backward compat)

    public typealias ConnectConfig = OpenClawConnectConfig
    public typealias ConnectionState = OpenClawConnectionState
    public typealias ChatMessage = OpenClawChatMessage
    public typealias Conversation = OpenClawConversation

    // MARK: - Protocol Constants

    /// OpenClaw gateway protocol version.
    static let protocolVersion = 3

    // MARK: - Protocol Frames (v3)

    /// Incoming frame — covers both response and event shapes.
    struct IncomingFrame: Decodable {
        let type: String?
        let id: String?
        let ok: Bool?
        let result: AnyCodable?
        let payload: AnyCodable?
        let error: FrameError?
        let event: String?
        let data: AnyCodable?

        // swiftlint:disable:next nesting
        struct FrameError: Decodable {
            let message: String
            let code: String?
        }
    }

    // MARK: - Properties

    var webSocket: URLSessionWebSocketTask?
    let urlSession: URLSession
    var config: ConnectConfig?
    var pendingRequests: [String: (Result<AnyCodable?, Error>) -> Void] = [:]
    let logger = Logger(subsystem: "com.justspeaktoit.ios", category: "OpenClawClient")
    var requestCounter = 0
    var isConnected = false
    var connectNonce: String?
    var reconnectTimer: Timer?

    // Callbacks
    public var onConnectionStateChanged: ((ConnectionState) -> Void)?
    public var onChatDelta: ((String, String) -> Void)?
    public var onChatFinal: ((String, String) -> Void)?
    public var onChatError: ((String, String) -> Void)?

    // MARK: - Init

    public init() {
        self.urlSession = URLSession(configuration: .default)
    }

    // MARK: - URL Normalisation

    /// Normalise a user-entered gateway address into a WebSocket URL.
    public static func normaliseGatewayURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if trimmed.hasPrefix("ws://") || trimmed.hasPrefix("wss://") {
            return trimmed
        }
        if trimmed.hasPrefix("https://") {
            return "wss://" + trimmed.dropFirst("https://".count)
        }
        if trimmed.hasPrefix("http://") {
            return "ws://" + trimmed.dropFirst("http://".count)
        }
        return "ws://" + trimmed
    }

    // MARK: - Connection

    public func connect(config: ConnectConfig) {
        self.config = config
        self.connectNonce = nil
        onConnectionStateChanged?(.connecting)

        let normalisedURL = Self.normaliseGatewayURL(config.gatewayURL)
        guard let url = URL(string: normalisedURL) else {
            onConnectionStateChanged?(.error("Invalid URL: \(config.gatewayURL)"))
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        webSocket = urlSession.webSocketTask(with: request)
        webSocket?.resume()

        logger.info("Connecting to \(normalisedURL)")
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

    /// Send a message and receive streaming responses via callbacks.
    public func sendMessage(
        _ message: String,
        sessionKey: String? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let key = sessionKey ?? config?.sessionKey ?? "speak-ios:voice"
        let reqId = nextRequestId()

        let params: [String: Any] = [
            "sessionKey": key,
            "message": message,
            "idempotencyKey": UUID().uuidString
        ]

        sendRequest(id: reqId, method: "chat.send", params: params) { result in
            switch result {
            case .success(let value):
                let runId = (value?.value as? [String: Any])?["runId"] as? String
                completion(.success(runId ?? ""))
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

        let params: [String: Any] = [
            "sessionKey": key,
            "limit": limit
        ]

        sendRequest(id: reqId, method: "chat.history", params: params) { result in
            switch result {
            case .success(let value):
                completion(.success(Self.parseHistory(value)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Internal Helpers

    func nextRequestId() -> String {
        requestCounter += 1
        return "req-\(requestCounter)"
    }

    /// Build and send a v3 request frame.
    func sendRequest(
        id: String,
        method: String,
        params: [String: Any],
        completion: ((Result<AnyCodable?, Error>) -> Void)? = nil
    ) {
        if let completion {
            pendingRequests[id] = completion
        }

        let frame: [String: Any] = [
            "type": "req",
            "id": id,
            "method": method,
            "params": params
        ]
        sendRawJSON(frame)
    }

    /// Send a raw JSON dictionary over the WebSocket.
    func sendRawJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else {
            logger.error("Failed to encode JSON frame")
            return
        }

        webSocket?.send(.string(text)) { [weak self] error in
            if let error {
                self?.logger.error("Send failed: \(error.localizedDescription)")
            }
        }
    }

    /// Parse history response into ChatMessage array.
    static func parseHistory(_ value: AnyCodable?) -> [ChatMessage] {
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
            return ChatMessage(id: id, role: role, content: content)
        }
    }
}
