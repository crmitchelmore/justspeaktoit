#if os(iOS)
import Foundation
import SpeakCore

// MARK: - Connection Tester

/// Tests WebSocket connectivity to an OpenClaw gateway
/// using the v3 challenge-response protocol.
enum OpenClawConnectionTester {
    /// Possible outcomes of a connection test.
    enum Result: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    static func test(rawURL: String, token: String) async -> Result {
        let normalisedURL = OpenClawClient.normaliseGatewayURL(rawURL)

        guard let url = URL(string: normalisedURL) else {
            return .failure("Invalid URL")
        }

        let start = CFAbsoluteTimeGetCurrent()

        return await withCheckedContinuation { cont in
            var request = URLRequest(url: url)
            request.timeoutInterval = 10

            let session = URLSession(configuration: .default)
            let task = session.webSocketTask(with: request)
            task.resume()

            waitForChallenge(task: task, token: token, start: start, cont: cont)
        }
    }

    /// Wait for the `connect.challenge` event from the gateway.
    private static func waitForChallenge(
        task: URLSessionWebSocketTask,
        token: String,
        start: CFAbsoluteTime,
        cont: CheckedContinuation<Result, Never>
    ) {
        task.receive { result in
            switch result {
            case .success(let message):
                guard let json = decodeFrame(message) else {
                    finish(task: task, cont: cont, state: .failure("Unexpected format"))
                    return
                }
                handleChallengeFrame(json, task: task, token: token, start: start, cont: cont)
            case .failure(let error):
                finish(task: task, cont: cont, state: .failure(error.localizedDescription))
            }
        }
    }

    /// Handle the challenge frame and send connect request.
    private static func handleChallengeFrame(
        _ json: [String: Any],
        task: URLSessionWebSocketTask,
        token: String,
        start: CFAbsoluteTime,
        cont: CheckedContinuation<Result, Never>
    ) {
        let event = json["event"] as? String
        guard event == "connect.challenge" else {
            finish(task: task, cont: cont, state: .failure("Expected challenge, got: \(event ?? "nil")"))
            return
        }

        sendConnectRequest(task: task, token: token, start: start, cont: cont)
    }

    /// Send the protocol v3 connect request with auth token.
    private static func sendConnectRequest(
        task: URLSessionWebSocketTask,
        token: String,
        start: CFAbsoluteTime,
        cont: CheckedContinuation<Result, Never>
    ) {
        let connectFrame: [String: Any] = [
            "type": "req",
            "id": "test-connect",
            "method": "connect",
            "params": [
                "minProtocol": 3,
                "maxProtocol": 3,
                "client": [
                    "id": "openclaw-ios",
                    "displayName": "Just Speak to It",
                    "version": "0.17.0",
                    "platform": "ios",
                    "mode": "cli"
                ] as [String: Any],
                "caps": [] as [String],
                "auth": ["token": token],
                "role": "operator",
                "scopes": ["operator.admin"]
            ] as [String: Any]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: connectFrame),
              let text = String(data: data, encoding: .utf8) else {
            finish(task: task, cont: cont, state: .failure("Encoding error"))
            return
        }

        task.send(.string(text)) { sendError in
            if let sendError {
                finish(task: task, cont: cont, state: .failure("Send: \(sendError.localizedDescription)"))
                return
            }
            receiveConnectResult(task: task, start: start, cont: cont)
        }
    }

    /// Read the gateway's response to our connect request.
    private static func receiveConnectResult(
        task: URLSessionWebSocketTask,
        start: CFAbsoluteTime,
        cont: CheckedContinuation<Result, Never>
    ) {
        task.receive { result in
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

            switch result {
            case .success(let message):
                guard let json = decodeFrame(message) else {
                    finish(task: task, cont: cont, state: .failure("Unexpected format"))
                    return
                }
                let state = evaluateConnectResponse(json, elapsed: elapsed)
                finish(task: task, cont: cont, state: state)
            case .failure(let error):
                finish(task: task, cont: cont, state: .failure(error.localizedDescription))
            }
        }
    }

    /// Evaluate whether the connect response indicates success.
    private static func evaluateConnectResponse(_ json: [String: Any], elapsed: Int) -> Result {
        if let err = json["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return .failure(msg)
        }
        if json["ok"] as? Bool == true {
            return .success("Connected (\(elapsed)ms)")
        }
        return .failure("Unexpected response")
    }

    // MARK: - Helpers

    private static func decodeFrame(_ message: URLSessionWebSocketTask.Message) -> [String: Any]? {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        case .data(let data):
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        @unknown default:
            return nil
        }
    }

    private static func finish(
        task: URLSessionWebSocketTask,
        cont: CheckedContinuation<Result, Never>,
        state: Result
    ) {
        task.cancel(with: .normalClosure, reason: nil)
        cont.resume(returning: state)
    }
}
#endif
