#if os(iOS)
import Foundation
import SpeakCore

@MainActor
protocol SonioxTTSWebSocketConnection: AnyObject {
    func resume()
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

@MainActor
protocol SonioxTTSWebSocketFactory {
    func makeConnection(to endpoint: URL) -> SonioxTTSWebSocketConnection
}

enum SonioxRealtimeTTSClientError: LocalizedError {
    case streamTimedOut

    var errorDescription: String? {
        "Soniox streaming response timed out"
    }
}

@MainActor
extension SonioxTTSWebSocketConnection {
    /// Receives one message, closing the connection when nothing arrives
    /// within `timeout` so a stalled stream ends as `streamTimedOut` rather
    /// than the socket error the close produces.
    func receive(timeout: Duration) async throws -> Data {
        let timeoutState = SonioxReceiveTimeoutState()
        let timeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            timeoutState.didFire = true
            self.close()
        }
        defer { timeoutTask.cancel() }
        do {
            return try await receive()
        } catch {
            if timeoutState.didFire { throw SonioxRealtimeTTSClientError.streamTimedOut }
            throw error
        }
    }
}

@MainActor
private final class SonioxReceiveTimeoutState {
    var didFire = false
}

@MainActor
private final class URLSessionSonioxTTSWebSocketConnection: SonioxTTSWebSocketConnection {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func resume() { task.resume() }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): data
        case .string(let string): Data(string.utf8)
        @unknown default: throw SonioxIOSVoiceOutputError.invalidWebSocketMessage
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

@MainActor
struct URLSessionSonioxTTSWebSocketFactory: SonioxTTSWebSocketFactory {
    let session: URLSession

    func makeConnection(to endpoint: URL) -> SonioxTTSWebSocketConnection {
        URLSessionSonioxTTSWebSocketConnection(task: session.webSocketTask(with: endpoint))
    }
}
#endif
