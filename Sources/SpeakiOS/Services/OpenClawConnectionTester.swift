#if os(iOS)
import Foundation
import SpeakCore

// MARK: - Connection Tester

/// Tests WebSocket connectivity to an OpenClaw gateway.
/// Extracted from OpenClawSettingsView for reuse and lint compliance.
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

            let connectPayload: [String: Any] = [
                "id": "test-1",
                "method": "connect",
                "params": [
                    "token": token,
                    "clientName": "speak-ios-test",
                    "mode": "chat",
                    "protocol": 1
                ]
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: connectPayload),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                task.cancel(with: .normalClosure, reason: nil)
                cont.resume(returning: .failure("Encoding error"))
                return
            }

            task.send(.string(jsonString)) { sendError in
                if let sendError {
                    task.cancel(with: .normalClosure, reason: nil)
                    cont.resume(returning: .failure("Send: \(sendError.localizedDescription)"))
                    return
                }
                receiveResult(task: task, start: start, cont: cont)
            }
        }
    }

    private static func receiveResult(
        task: URLSessionWebSocketTask,
        start: CFAbsoluteTime,
        cont: CheckedContinuation<Result, Never>
    ) {
        task.receive { result in
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            let state: Result

            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let err = json["error"] as? [String: Any],
                       let msg = err["message"] as? String {
                        state = .failure(msg)
                    } else if json["result"] != nil || json["id"] != nil {
                        state = .success("Connected (\(elapsed)ms)")
                    } else {
                        state = .failure("Unexpected response")
                    }
                } else {
                    state = .failure("Unexpected format")
                }
            case .failure(let error):
                state = .failure(error.localizedDescription)
            }

            task.cancel(with: .normalClosure, reason: nil)
            cont.resume(returning: state)
        }
    }
}
#endif
