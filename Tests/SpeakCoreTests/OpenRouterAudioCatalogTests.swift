import Foundation
import XCTest
@testable import SpeakCore

@MainActor
final class OpenRouterAudioCatalogTests: XCTestCase {
    nonisolated private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRefresh_UsesDedicatedFilterAndPersistsOnlyMetadata() async throws {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        OpenRouterCatalogMockProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            XCTAssertEqual(
                components?.queryItems, [URLQueryItem(name: "output_modalities", value: "speech,transcription")]
            )
            return Self.response(request, body: Self.body)
        }
        let catalog = OpenRouterAudioCatalog(
            apiKeyProvider: { "test-secret" }, session: mockSession(), cacheURL: cache, clock: { self.now }
        )

        await catalog.refresh()

        XCTAssertEqual(catalog.models.map(\.id), ["vendor/speech"])
        XCTAssertEqual(catalog.models(for: .speech).count, 1)
        XCTAssertTrue(catalog.models(for: .transcription).isEmpty)
        XCTAssertEqual(catalog.lastUpdated, now)
        XCTAssertFalse(catalog.isStale)
        XCTAssertNil(catalog.errorMessage)
        let serialized = try String(contentsOf: cache)
        XCTAssertFalse(serialized.contains("test-secret"))
        XCTAssertFalse(serialized.contains("Authorization"))
        XCTAssertFalse(serialized.contains("unknown_private_field"))
    }

    func testFreshCache_SkipsNetworkUntilForced() async throws {
        let cache = try seededCache(updatedAt: now)
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let calls = OpenRouterCatalogRequestCount()
        OpenRouterCatalogMockProtocol.handler = { request in
            await calls.increment()
            return Self.response(request, body: #"{"data":[]}"#)
        }
        let catalog = OpenRouterAudioCatalog(session: mockSession(), cacheURL: cache, clock: { self.now })

        await catalog.refresh()
        let skippedCount = await calls.value
        XCTAssertEqual(skippedCount, 0)
        XCTAssertEqual(catalog.models.count, 1)
        await catalog.refresh(force: true)
        let forcedCount = await calls.value
        XCTAssertEqual(forcedCount, 1)
        XCTAssertTrue(catalog.models.isEmpty)
    }

    func testExpiredCacheAndHTTPError_KeepMetadataAndSanitizeError() async throws {
        let updatedAt = now.addingTimeInterval(-OpenRouterAudioCatalog.cacheLifetime)
        let cache = try seededCache(updatedAt: updatedAt)
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        OpenRouterCatalogMockProtocol.handler = { request in
            Self.response(request, status: 503, body: "Authorization: Bearer test-secret")
        }
        let catalog = OpenRouterAudioCatalog(session: mockSession(), cacheURL: cache, clock: { self.now })

        XCTAssertTrue(catalog.isStale)
        await catalog.refresh()

        XCTAssertEqual(catalog.models.count, 1)
        XCTAssertEqual(catalog.lastUpdated, updatedAt)
        XCTAssertEqual(catalog.errorMessage, "OpenRouter could not load audio models (HTTP 503).")
        XCTAssertFalse(catalog.isRefreshing)
        let snapshot = OpenRouterAudioCatalogSnapshot.read(from: cache, now: now)
        XCTAssertEqual(snapshot?.updatedAt, updatedAt)
    }

    func testMalformedRefresh_DoesNotOverwriteCache() async throws {
        let updatedAt = now.addingTimeInterval(-30_000)
        let cache = try seededCache(updatedAt: updatedAt)
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        OpenRouterCatalogMockProtocol.handler = { request in
            Self.response(request, body: #"{"data":[{"id":false}]}"#)
        }
        let catalog = OpenRouterAudioCatalog(session: mockSession(), cacheURL: cache, clock: { self.now })

        await catalog.refresh()

        XCTAssertEqual(catalog.models.count, 1)
        XCTAssertEqual(catalog.lastUpdated, updatedAt)
        XCTAssertNotNil(catalog.errorMessage)
        XCTAssertEqual(OpenRouterAudioCatalogSnapshot.read(from: cache, now: now)?.updatedAt, updatedAt)
    }

    func testCorruptAndFutureDatedCaches_AreIgnored() throws {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not JSON".utf8).write(to: cache)
        XCTAssertTrue(OpenRouterAudioCatalog(cacheURL: cache).models.isEmpty)
        let models = try JSONDecoder().decode(OpenRouterAudioModelResponse.self, from: Data(Self.body.utf8)).data
        OpenRouterAudioCatalogSnapshot(version: 1, updatedAt: now.addingTimeInterval(1), models: models)
            .write(to: cache)
        XCTAssertTrue(OpenRouterAudioCatalog(cacheURL: cache, clock: { self.now }).models.isEmpty)
    }

    func testCancellation_PreservesCacheWithoutError() async throws {
        let cache = try seededCache(updatedAt: now.addingTimeInterval(-30_000))
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let started = expectation(description: "Key lookup started")
        let gate = OpenRouterCatalogKeyGate(started: started)
        let catalog = OpenRouterAudioCatalog(
            apiKeyProvider: { await gate.key() }, session: mockSession(), cacheURL: cache, clock: { self.now }
        )
        let refresh = Task { await catalog.refresh() }
        await fulfillment(of: [started], timeout: 2)
        refresh.cancel()
        await gate.release()
        await refresh.value

        XCTAssertEqual(catalog.models.count, 1)
        XCTAssertTrue(catalog.isStale)
        XCTAssertFalse(catalog.isRefreshing)
        XCTAssertNil(catalog.errorMessage)
    }

    func testOverlappingForcedRefresh_OlderWorkCannotReplaceNewerResult() async {
        let started = expectation(description: "First key lookup started")
        let gate = OpenRouterCatalogKeyGate(started: started)
        OpenRouterCatalogMockProtocol.handler = { request in Self.response(request, body: Self.body) }
        let catalog = OpenRouterAudioCatalog(
            apiKeyProvider: { await gate.key() }, session: mockSession(), cacheURL: nil, clock: { self.now }
        )
        let first = Task { await catalog.refresh() }
        await fulfillment(of: [started], timeout: 2)

        await catalog.refresh(force: true)
        await gate.release()
        await first.value

        XCTAssertEqual(catalog.models.map(\.id), ["vendor/speech"])
        XCTAssertEqual(catalog.lastUpdated, now)
        XCTAssertFalse(catalog.isRefreshing)
        XCTAssertNil(catalog.errorMessage)
    }

    func testOversizedResponse_IsRejectedBeforeDecoding() async {
        OpenRouterCatalogMockProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Length": "\(OpenRouterAudioCatalogSnapshot.maximumBytes + 1)"]
            )!
            return (response, Data())
        }
        let catalog = OpenRouterAudioCatalog(session: mockSession(), cacheURL: nil)

        await catalog.refresh()

        XCTAssertTrue(catalog.models.isEmpty)
        XCTAssertEqual(catalog.errorMessage, "OpenRouter's audio model catalogue exceeded the download limit.")
    }

    private func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterCatalogMockProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func temporaryCache() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("catalog.json")
    }

    private func seededCache(updatedAt: Date) throws -> URL {
        let cache = temporaryCache()
        let models = try JSONDecoder().decode(OpenRouterAudioModelResponse.self, from: Data(Self.body.utf8)).data
        OpenRouterAudioCatalogSnapshot(version: 1, updatedAt: updatedAt, models: models).write(to: cache)
        return cache
    }

    nonisolated private static let body = """
    {"data":[{"id":"vendor/speech","architecture":{"input_modalities":["text"],"output_modalities":["speech"]},
    "supported_voices":["voice-one"],"pricing":{"prompt":"0.0001"},"unknown_private_field":"ignored"}]}
    """

    nonisolated private static func response(
        _ request: URLRequest, status: Int = 200, body: String
    ) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }
}

private actor OpenRouterCatalogRequestCount {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor OpenRouterCatalogKeyGate {
    private let started: XCTestExpectation
    private var continuation: CheckedContinuation<String?, Never>?
    private var calls = 0

    init(started: XCTestExpectation) { self.started = started }

    func key() async -> String? {
        calls += 1
        guard calls == 1 else { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func release() {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}

private final class OpenRouterCatalogMockProtocol: URLProtocol {
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
