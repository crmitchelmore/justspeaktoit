#if os(iOS)
import Foundation
import SpeakCore
import XCTest

@testable import SpeakiOSLib

/// Shared doubles and wait helpers for the Soniox real-time voice-output tests.
@MainActor
final class MockSonioxWebSocketFactory: SonioxTTSWebSocketFactory {
    private var connections: [MockSonioxWebSocketConnection]
    private(set) var endpoints: [URL] = []

    init(connections: [MockSonioxWebSocketConnection]) {
        self.connections = connections
    }

    func makeConnection(to endpoint: URL) -> SonioxTTSWebSocketConnection {
        endpoints.append(endpoint)
        return connections.removeFirst()
    }
}

@MainActor
final class MockSonioxWebSocketConnection: SonioxTTSWebSocketConnection {
    var sent: [Data] = []
    var responses: [Data] = []
    var rewriteStreamID = false
    var blocksCancelSend = false
    /// Reproduces an abrupt server close once the queued responses are consumed.
    var receiveFailure: Error?
    private var receiveContinuation: CheckedContinuation<Data, Error>?
    private var sendContinuation: CheckedContinuation<Void, Error>?
    private(set) var didResume = false
    private(set) var didClose = false

    func resume() { didResume = true }

    func send(_ data: Data) async throws {
        sent.append(data)
        guard !didClose else { throw CancellationError() }
        guard blocksCancelSend,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["cancel"] as? Bool == true else { return }
        try await withCheckedThrowingContinuation { continuation in
            self.sendContinuation = continuation
        }
    }

    func receive() async throws -> Data {
        if !responses.isEmpty {
            return responseWithCurrentStreamID(responses.removeFirst())
        }
        if let receiveFailure { throw receiveFailure }
        return try await withCheckedThrowingContinuation { continuation in
            self.receiveContinuation = continuation
        }
    }

    func close() {
        didClose = true
        sendContinuation?.resume(throwing: CancellationError())
        sendContinuation = nil
        receiveContinuation?.resume(throwing: CancellationError())
        receiveContinuation = nil
    }

    func push(_ data: Data) {
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            continuation.resume(returning: responseWithCurrentStreamID(data))
        } else {
            responses.append(data)
        }
    }

    private func responseWithCurrentStreamID(_ data: Data) -> Data {
        guard rewriteStreamID,
              let first = sent.first,
              let object = try? JSONSerialization.jsonObject(with: first) as? [String: Any],
              let streamID = object["stream_id"] as? String,
              let string = String(data: data, encoding: .utf8) else { return data }
        return Data(string.replacingOccurrences(of: "STREAM", with: streamID).utf8)
    }
}

@MainActor
final class MockSonioxPCMAudioPlayer: SonioxPCMAudioPlaying {
    private(set) var preparedStreamIDs: [String] = []
    private(set) var enqueued: [(data: Data, streamID: String)] = []
    private(set) var stoppedStreamIDs: [String?] = []
    private(set) var pausedStreamIDs: [String] = []
    private(set) var resumedStreamIDs: [String] = []

    func prepare(streamID: String) throws { preparedStreamIDs.append(streamID) }
    func enqueue(_ data: Data, isFinal _: Bool, streamID: String) throws -> Bool {
        enqueued.append((data, streamID))
        return true
    }
    func waitUntilDrained(streamID: String) async {}
    func pause(streamID: String) { pausedStreamIDs.append(streamID) }
    func resume(streamID: String) { resumedStreamIDs.append(streamID) }
    func stop(streamID: String?) { stoppedStreamIDs.append(streamID) }
}

extension XCTestCase {
    func eventData(_ json: String) -> Data { Data(json.utf8) }

    func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor
    func waitForSentMessages(_ count: Int, on connection: MockSonioxWebSocketConnection) async throws {
        for _ in 0..<100 where connection.sent.count < count {
            await Task.yield()
        }
        guard connection.sent.count >= count else {
            XCTFail("Expected \(count) sent messages, observed \(connection.sent.count)")
            throw CancellationError()
        }
    }
}
#endif
