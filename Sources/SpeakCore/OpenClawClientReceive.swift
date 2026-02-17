import Foundation

// MARK: - OpenClawClient WebSocket Receive & Event Handling

extension OpenClawClient {

    /// Start the WebSocket receive loop.
    func receiveMessages() {
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
                self.logger.error("Receive error: \(error.localizedDescription)")
                self.isConnected = false
                self.onConnectionStateChanged?(.error(error.localizedDescription))
            }
        }
    }

    /// Route an incoming text frame to the appropriate handler.
    func handleIncomingMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONDecoder().decode(IncomingFrame.self, from: data) else {
            return
        }

        if frame.type == "event", let event = frame.event {
            handleEvent(event, payload: frame.payload)
            return
        }

        if frame.type == "res", let id = frame.id {
            if let error = frame.error {
                pendingRequests[id]?(.failure(OpenClawError.serverError(error.message)))
            } else {
                pendingRequests[id]?(.success(frame.payload ?? frame.result))
            }
            pendingRequests.removeValue(forKey: id)
        }
    }

    // MARK: - Event Dispatch

    /// Handle a gateway event.
    func handleEvent(_ event: String, payload: AnyCodable?) {
        if event == "connect.challenge" {
            if let dict = payload?.value as? [String: Any],
               let nonce = dict["nonce"] as? String {
                logger.info("Challenge nonce: \(nonce)")
                self.connectNonce = nonce
            }
            sendConnectHandshake()
            return
        }

        guard event == "chat",
              let dict = payload?.value as? [String: Any],
              let runId = dict["runId"] as? String,
              let state = dict["state"] as? String else {
            return
        }

        dispatchChatEvent(state: state, runId: runId, dict: dict)
    }

    /// Dispatch a chat event to the appropriate callback.
    private func dispatchChatEvent(state: String, runId: String, dict: [String: Any]) {
        switch state {
        case "delta":
            onChatDelta?(runId, Self.extractContent(from: dict))
        case "final":
            onChatFinal?(runId, Self.extractContent(from: dict))
        case "error":
            let msg = dict["errorMessage"] as? String ?? "Unknown error"
            onChatError?(runId, msg)
        case "aborted":
            onChatError?(runId, "Response was aborted")
        default:
            break
        }
    }

    // MARK: - Connect Handshake

    /// Send the v3 connect handshake after receiving the challenge nonce.
    func sendConnectHandshake() {
        guard let config else { return }

        let reqId = nextRequestId()
        let params: [String: Any] = [
            "minProtocol": Self.protocolVersion,
            "maxProtocol": Self.protocolVersion,
            "client": [
                "id": "openclaw-ios",
                "displayName": "Just Speak to It",
                "version": "0.17.0",
                "platform": "ios",
                "mode": "cli"
            ] as [String: Any],
            "caps": [] as [String],
            "auth": ["token": config.token],
            "role": "operator",
            "scopes": ["operator.admin"]
        ]

        pendingRequests[reqId] = { [weak self] result in
            switch result {
            case .success:
                self?.isConnected = true
                self?.onConnectionStateChanged?(.connected)
                self?.logger.info("Connected to gateway")
            case .failure(let error):
                self?.isConnected = false
                let desc = error.localizedDescription
                self?.onConnectionStateChanged?(.error(desc))
            }
        }

        sendRequest(id: reqId, method: "connect", params: params)
    }

    // MARK: - Content Extraction

    /// Extract text content from a chat event message.
    /// Content may be a plain string or structured blocks:
    /// `[{ "type": "text", "text": "..." }]`
    static func extractContent(from dict: [String: Any]) -> String {
        guard let message = dict["message"] as? [String: Any] else { return "" }

        if let text = message["content"] as? String { return text }

        if let blocks = message["content"] as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            }.joined()
        }
        return ""
    }
}
