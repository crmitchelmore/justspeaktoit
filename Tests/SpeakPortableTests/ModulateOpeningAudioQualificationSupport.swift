import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

final class ModulateOpeningHarness: @unchecked Sendable {
    let identifiers: [String]
    let peer: ModulateOpeningPeer
    let client: ModulateLiveClient
    let events: ModulateOpeningEvents
    private let session: URLSession

    init(sessionCount: Int) throws {
        #if canImport(FoundationNetworking)
        throw XCTSkip("This qualification requires the actual Apple URLSession WebSocket adapter")
        #else
        guard let value = ProcessInfo.processInfo.environment["JSTI_MODULATE_OPENING_PROBE_PORT"],
              let port = Int(value), (1...65535).contains(port) else {
            throw XCTSkip("Requires scripts/modulate-opening-audio-probe.py on an ephemeral loopback port")
        }
        let identifiers = (0..<sessionCount).map { _ in UUID().uuidString.lowercased() }
        let events = ModulateOpeningEvents(identifiers: identifiers)
        let session = URLSession(configuration: .ephemeral)
        self.identifiers = identifiers
        self.events = events
        self.session = session
        peer = ModulateOpeningPeer(port: port)
        client = ModulateLiveClient(apiKey: "synthetic-loopback-key", makeConnection: { request in
            let identifier = events.nextIdentifier()
            var local = request
            var url = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                ?? URLComponents()
            url.scheme = "ws"
            url.host = "127.0.0.1"
            url.port = port
            local.url = url.url
            local.setValue("local-only", forHTTPHeaderField: "X-JSTI-Probe")
            local.setValue("jsti-probe", forHTTPHeaderField: "Sec-WebSocket-Protocol")
            local.setValue(identifier, forHTTPHeaderField: "X-JSTI-Opening-Session")
            return ModulateOpeningConnection(
                native: URLSessionStreamingConnection(session: session, request: local),
                identifier: identifier, events: events
            )
        })
        #endif
    }

    func start(heard: XCTestExpectation? = nil, failed: XCTestExpectation? = nil) {
        client.start(onTranscript: { text, _ in
            if text == "Opening verified." { heard?.fulfill() }
        }, onError: { [events] error in
            events.fail(error)
            failed?.fulfill()
        })
    }

    func offer(_ ids: [Int]) { ids.forEach { client.sendAudio(Self.frame($0)) } }

    static func frame(_ identifier: Int) -> Data {
        var littleEndian = UInt32(identifier).littleEndian
        var data = Data(bytes: &littleEndian, count: 4)
        data.append(contentsOf: (4..<3200).map { UInt8(truncatingIfNeeded: identifier * 31 + $0 * 7) })
        return data
    }

    func taskStates(_ identifier: String, test: XCTestCase) async -> [URLSessionTask.State] {
        let received = XCTestExpectation(description: "Owned Apple task-state callback")
        let events = events
        session.getAllTasks { tasks in
            let owned = tasks.filter {
                $0.originalRequest?.value(forHTTPHeaderField: "X-JSTI-Opening-Session") == identifier
            }
            events.recordStates(identifier, states: owned.map(\.state))
            received.fulfill()
        }
        await test.fulfillment(of: [received], timeout: 2)
        return events.states(identifier)
    }

    func cleanup() async {
        client.stop()
        // Release every owned barrier even when an assertion/startup request failed.
        for identifier in identifiers { _ = try? await peer.act(identifier, action: "release") }
        session.invalidateAndCancel()
        peer.invalidate()
    }
}

struct ModulateOpeningReceipt: Decodable {
    let stage: String
    let upgradeComplete: Bool
    let receivedIDs: [Int]
    let receivedPCMBytes: Int
    let upgradeHoldMilliseconds: Double
    let wavHeaders: Int
    let endVerified: Bool
}

final class ModulateOpeningPeer: @unchecked Sendable {
    private let port: Int
    private let session = URLSession(configuration: .ephemeral)
    init(port: Int) { self.port = port }
    func invalidate() { session.invalidateAndCancel() }

    func configure(_ identifier: String, ids: [Int], ackAfter: Int) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["ids": ids, "ackAfter": ackAfter])
        _ = try await request(identifier, action: "configure", body: body)
    }

    @discardableResult
    func act(_ identifier: String, action: String) async throws -> ModulateOpeningReceipt {
        try await request(identifier, action: action)
    }

    func state(_ identifier: String) async throws -> ModulateOpeningReceipt {
        try await request(identifier, action: "state")
    }

    func wait(_ identifier: String, stages: Set<String>) async throws {
        let action = stages == ["held"] ? "await-held" : "await-ended"
        let receipt = try await request(identifier, action: action)
        guard stages.contains(receipt.stage) else { throw URLError(.timedOut) }
    }

    private func request(
        _ identifier: String, action: String, body: Data? = nil
    ) async throws -> ModulateOpeningReceipt {
        let url = URL(string: "http://127.0.0.1:\(port)/control/\(identifier)/\(action)")!
        var request = URLRequest(url: url, timeoutInterval: action.hasPrefix("await-") ? 5 : 2)
        request.httpMethod = action == "state" ? "GET" : "POST"
        request.setValue("local-only", forHTTPHeaderField: "X-JSTI-Probe")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(ModulateOpeningReceipt.self, from: data)
    }
}

final class ModulateOpeningEvents: @unchecked Sendable {
    private let lock = NSLock()
    private let identifiers: [String]
    private var created = 0
    private var openCounts: [String: Int] = [:]
    private var sendCounts: [String: Int] = [:]
    private var failures: [Error] = []
    private var observedStates: [String: [URLSessionTask.State]] = [:]
    var errors: [Error] { lock.withLock { failures } }
    init(identifiers: [String]) { self.identifiers = identifiers }

    func nextIdentifier() -> String {
        lock.withLock {
            let identifier = identifiers[min(created, identifiers.count - 1)]
            created += 1
            return identifier
        }
    }
    func recordStates(_ identifier: String, states: [URLSessionTask.State]) {
        lock.withLock { observedStates[identifier] = states }
    }
    func states(_ identifier: String) -> [URLSessionTask.State] { lock.withLock { observedStates[identifier] ?? [] } }
    func opened(_ identifier: String) { lock.withLock { openCounts[identifier, default: 0] += 1 } }
    func sent(_ identifier: String) { lock.withLock { sendCounts[identifier, default: 0] += 1 } }
    func fail(_ error: Error) { lock.withLock { failures.append(error) } }
    func opens(_ identifier: String) -> Int { lock.withLock { openCounts[identifier, default: 0] } }
    func sends(_ identifier: String) -> Int { lock.withLock { sendCounts[identifier, default: 0] } }
}

private final class ModulateOpeningConnection: StreamingWebSocketConnection, @unchecked Sendable {
    private let native: any StreamingWebSocketConnection
    private let identifier: String
    private let events: ModulateOpeningEvents
    init(native: any StreamingWebSocketConnection, identifier: String, events: ModulateOpeningEvents) {
        self.native = native
        self.identifier = identifier
        self.events = events
    }
    func resume(onOpen: @escaping @Sendable () -> Void) {
        native.resume { [events, identifier] in events.opened(identifier); onOpen() }
    }
    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        events.sent(identifier)
        native.send(message, completion: completion)
    }
    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        native.receive(completion: completion)
    }
    func cancel() { native.cancel() }
}
