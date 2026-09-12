import Foundation
import XCTest
@testable import SpeakCore

@MainActor
final class OpenRouterAudioCatalogOrderingTests: XCTestCase {
    func testTwoInstances_OlderResponseCannotOverwriteNewerSuccessfulCache() async throws {
        let models = try await cachedModelsAfterRace(newerStatus: 200)
        XCTAssertEqual(models, ["vendor/newer"])
    }

    func testTwoInstances_NewerFailedRequestDoesNotBlockOlderSuccess() async throws {
        let models = try await cachedModelsAfterRace(newerStatus: 503)
        XCTAssertEqual(models, ["vendor/older"])
    }

    func testNewerPersistedSnapshot_IsNotOverwrittenAcrossProcessOrders() throws {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let now = Date()
        let existing = OpenRouterAudioCatalogSnapshot(
            version: 1, updatedAt: now, models: try models("vendor/newer"),
            requestOrder: OpenRouterAudioCatalogRequestOrder(processID: UUID(), ordinal: 1, startedAt: now)
        )
        existing.write(to: cache)
        let candidate = OpenRouterAudioCatalogSnapshot(
            version: 1, updatedAt: now.addingTimeInterval(10), models: try models("vendor/older"),
            requestOrder: .begin(at: now.addingTimeInterval(-10))
        )

        candidate.write(to: cache)

        XCTAssertEqual(
            OpenRouterAudioCatalogSnapshot.read(from: cache, now: now)?.models.map(\.id), ["vendor/newer"]
        )
    }

    private func cachedModelsAfterRace(newerStatus: Int) async throws -> [String] {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let started = expectation(description: "Older request waits for its response")
        let gate = OpenRouterCatalogResponseGate(started: started)
        let now = Date()
        OpenRouterCatalogOrderingProtocol.handler = { request in
            let isOlder = request.value(forHTTPHeaderField: "Authorization") == "Bearer older"
            if isOlder { await gate.wait() }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: isOlder ? 200 : newerStatus, httpVersion: nil, headerFields: nil
            )!
            return (response, Self.body(isOlder ? "vendor/older" : "vendor/newer"))
        }
        let session = mockSession()
        defer {
            session.invalidateAndCancel()
            OpenRouterCatalogOrderingProtocol.handler = nil
        }
        let first = OpenRouterAudioCatalog(
            apiKeyProvider: { "older" }, session: session, cacheURL: cache, clock: { now }
        )
        let alias = cache.deletingLastPathComponent().appendingPathComponent("./catalog.json")
        let second = OpenRouterAudioCatalog(
            apiKeyProvider: { "newer" }, session: session, cacheURL: alias, clock: { now }
        )
        let olderRefresh = Task { await first.refresh() }
        await fulfillment(of: [started], timeout: 2)
        await second.refresh()
        await gate.release()
        await olderRefresh.value

        XCTAssertEqual(first.models.map(\.id), ["vendor/older"])
        XCTAssertFalse(first.isRefreshing)
        XCTAssertFalse(second.isRefreshing)
        let restored = OpenRouterAudioCatalog(cacheURL: cache, clock: { now })
        return restored.models.map(\.id)
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterCatalogOrderingProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func temporaryCache() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("catalog.json")
    }

    private func models(_ identifier: String) throws -> [OpenRouterAudioModel] {
        try JSONDecoder().decode(OpenRouterAudioModelResponse.self, from: Self.body(identifier)).data
    }

    nonisolated private static func body(_ identifier: String) -> Data {
        Data("""
        {"data":[{"id":"\(identifier)","architecture":{
          "input_modalities":["audio"],"output_modalities":["transcription"]
        }}]}
        """.utf8)
    }
}

private actor OpenRouterCatalogResponseGate {
    private let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(started: XCTestExpectation) { self.started = started }

    func wait() async {
        started.fulfill()
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class OpenRouterCatalogOrderingProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) async throws -> (HTTPURLResponse, Data))?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        Task {
            do {
                let (response, data) = try await handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}
