#if DEBUG
import Foundation
import SpeakCore

/// One launch's ordered HTTP conversation. The registry holds weak references;
/// each profile owns its own sequence and no request is ever forwarded.
final class CoreJourneyPolishFixture: @unchecked Sendable {
    struct Reply {
        let status: Int
        let data: Data
    }

    let key: String
    private let directory: URL
    private let scenario: CoreJourneyBatchScenario
    private let session: URLSession
    private let lock = NSLock()
    private var sequence: [String] = []
    private var rejected = 0

    init(identifier: UUID, directory: URL, scenario: CoreJourneyBatchScenario) {
        self.key = "core-journey-fixture-\(identifier.uuidString)"
        self.directory = directory
        self.scenario = scenario
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CoreJourneyPolishURLProtocol.self]
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
        CoreJourneyPolishRegistry.shared.register(self)
    }

    deinit {
        self.session.invalidateAndCancel()
        CoreJourneyPolishRegistry.shared.remove(self.key)
    }

    func close() { self.session.invalidateAndCancel() }

    func makeClient() -> OpenRouterAPIClient {
        let key = self.key
        return OpenRouterAPIClient(
            apiKeyProvider: { key }, session: self.session
        )
    }

    func reply(to request: URLRequest) throws -> Reply {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard self.scenario.polishes,
              request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions",
              request.httpMethod == "POST",
              request.value(forHTTPHeaderField: "Content-Type") == "application/json",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer \(self.key)",
              let body = CoreJourneyBatchURLProtocol.body(of: request),
              self.sequence.count < (self.scenario == .batchPolishSuccess ? 2 : 4) else {
            return try self.reject()
        }
        let step = self.sequence.count
        let raw = step < 2 ? CoreJourneyBatchScenario.rawA : CoreJourneyBatchScenario.rawB
        if step.isMultiple(of: 2) {
            var audioRequest = request
            audioRequest.httpBodyStream = nil
            audioRequest.httpBody = body
            audioRequest.setValue("Bearer core-journey-fixture-not-a-real-key", forHTTPHeaderField: "Authorization")
            guard CoreJourneyBatchURLProtocol.accepts(audioRequest) else { return try self.reject() }
            self.sequence.append(step == 0 ? "batchA" : "batchB")
            try self.persist()
            return try self.success(raw, model: CoreJourneyBatchFixture.model)
        }
        guard self.acceptsPolish(body, raw: raw) else { return try self.reject() }
        self.sequence.append(step == 1 ? "polishA" : "polishB")
        try self.persist()
        if self.scenario == .batchPolishFailureThenSuccess && step == 1 {
            return Reply(status: 400, data: try JSONSerialization.data(withJSONObject: [
                "error": ["message": CoreJourneyBatchScenario.failureMessage]
            ]))
        }
        return try self.success(
            step == 1 ? CoreJourneyBatchScenario.polishedA : CoreJourneyBatchScenario.polishedB,
            model: CoreJourneyBatchScenario.polishModel
        )
    }

    private func acceptsPolish(_ data: Data, raw: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["model", "temperature", "messages"]),
              let messages = object["messages"] as? [[String: Any]],
              messages.allSatisfy({ Set($0.keys) == Set(["role", "content"]) }),
              let request = try? JSONDecoder().decode(PolishRequest.self, from: data),
              request.model == CoreJourneyBatchScenario.polishModel, request.temperature == 0 else { return false }
        // Production's nonstreaming serializer omits stream; requiring the exact
        // key set rejects SSE and unexpected fields without changing that contract.
        return request.messages == [
            .init(role: "system", content: CoreJourneyBatchScenario.systemPrompt),
            .init(role: "user", content: TranscriptCleanupPolicy.userMessage(transcript: raw))
        ]
    }

    private struct PolishMessage: Decodable, Equatable {
        let role: String
        let content: String
    }

    private struct PolishRequest: Decodable {
        let model: String
        let temperature: Double
        let messages: [PolishMessage]
    }

    private func success(_ text: String, model: String) throws -> Reply {
        Reply(status: 200, data: try JSONSerialization.data(withJSONObject: [
            "id": "synthetic-journey-response", "model": model,
            "choices": [["index": 0, "message": ["role": "assistant", "content": text]]]
        ]))
    }

    private func reject() throws -> Reply {
        self.rejected += 1
        try self.persist()
        throw URLError(.badServerResponse)
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: [
            "acceptedRequests": self.sequence.count, "rejectedRequests": self.rejected, "sequence": self.sequence
        ], options: [.sortedKeys])
        try data.write(to: self.directory.appendingPathComponent("batch-http.json"), options: .atomic)
    }
}

private final class CoreJourneyPolishRegistry: @unchecked Sendable {
    static let shared = CoreJourneyPolishRegistry()
    private final class Entry {
        weak var fixture: CoreJourneyPolishFixture?
        init(_ fixture: CoreJourneyPolishFixture) { self.fixture = fixture }
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func register(_ fixture: CoreJourneyPolishFixture) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries[fixture.key] = Entry(fixture)
    }

    func remove(_ key: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.entries.removeValue(forKey: key)
    }

    func fixture(for request: URLRequest) -> CoreJourneyPolishFixture? {
        guard let authorization = request.value(forHTTPHeaderField: "Authorization"),
              authorization.hasPrefix("Bearer ") else { return nil }
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.entries[String(authorization.dropFirst(7))]?.fixture
    }
}

private final class CoreJourneyPolishURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let fixture = CoreJourneyPolishRegistry.shared.fixture(for: self.request),
                  let url = self.request.url else { throw URLError(.badServerResponse) }
            let reply = try fixture.reply(to: self.request)
            guard let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil
            ) else { throw URLError(.badServerResponse) }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: reply.data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
#endif
