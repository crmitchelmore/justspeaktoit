import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

/// Shared OpenRouter audio discovery on the portable graph: the same filter, cache and
/// ordering contracts the Apple hosts rely on, without Combine or `URLSession.bytes`.
final class OpenRouterAudioCatalogPortableTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    @MainActor
    func testRefreshRequestsDedicatedModalitiesAndKeepsOnlyDedicatedModels() async throws {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            XCTAssertEqual(components?.host, "openrouter.ai")
            XCTAssertEqual(components?.path, "/api/v1/models")
            XCTAssertEqual(
                components?.queryItems, [URLQueryItem(name: "output_modalities", value: "speech,transcription")]
            )
            return .ok(Data(Self.mixedCatalogue.utf8), url: request.url!)
        }
        let catalog = OpenRouterAudioCatalog(
            apiKeyProvider: { "test-secret" }, session: StubURLProtocol.makeSession(), cacheURL: cache,
            clock: { self.now }
        )

        await catalog.refresh()

        XCTAssertEqual(catalog.models.map(\.id), ["vendor/stt", "vendor/tts"])
        XCTAssertEqual(catalog.models(for: .transcription).map(\.id), ["vendor/stt"])
        XCTAssertEqual(catalog.models(for: .speech).map(\.id), ["vendor/tts"])
        XCTAssertEqual(catalog.models.first?.transcriptionSelectionID, "openrouter/transcription/vendor/stt")
        XCTAssertEqual(catalog.lastUpdated, now)
        XCTAssertFalse(catalog.isStale)
        XCTAssertFalse(catalog.isRefreshing)
        XCTAssertNil(catalog.errorMessage)
        // Only decoded metadata is persisted: no request headers, keys or unknown provider fields.
        let serialized = try String(contentsOf: cache, encoding: .utf8)
        XCTAssertFalse(serialized.contains("chat"))
        XCTAssertFalse(serialized.contains("test-secret"))
        XCTAssertFalse(serialized.contains("Authorization"))
        XCTAssertFalse(serialized.contains("private_field"))
        XCTAssertEqual(OpenRouterAudioCatalogSnapshot.read(from: cache, now: now)?.models, catalog.models)
        XCTAssertEqual(OpenRouterAudioCatalog(cacheURL: cache, clock: { self.now }).models, catalog.models)
    }

    @MainActor
    func testUnreadableRefreshCannotEraseAGoodCacheButAnEmptyCatalogueRetiresIt() async throws {
        let updatedAt = now.addingTimeInterval(-30_000)
        let cache = try seededCache(updatedAt: updatedAt)
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        StubURLProtocol.handler = { request in .ok(Data(#"{"data":[null,{"id":false}]}"#.utf8), url: request.url!) }
        let catalog = catalog(cacheURL: cache)

        await catalog.refresh()

        XCTAssertEqual(catalog.models.map(\.id), ["vendor/retained"])
        XCTAssertEqual(catalog.lastUpdated, updatedAt)
        XCTAssertTrue(catalog.isStale)
        XCTAssertEqual(catalog.errorMessage, "OpenRouter returned an unreadable audio model catalogue.")
        XCTAssertEqual(OpenRouterAudioCatalogSnapshot.read(from: cache, now: now)?.updatedAt, updatedAt)

        StubURLProtocol.handler = { request in .ok(Data(#"{"data":[]}"#.utf8), url: request.url!) }
        await catalog.refresh(force: true)

        XCTAssertTrue(catalog.models.isEmpty)
        XCTAssertEqual(catalog.lastUpdated, now)
        XCTAssertNil(catalog.errorMessage)
        XCTAssertEqual(OpenRouterAudioCatalogSnapshot.read(from: cache, now: now)?.models, [])
    }

    @MainActor
    func testHTTPFailureAndOversizedCatalogueKeepStaleMetadataWithSanitisedErrors() async throws {
        let updatedAt = now.addingTimeInterval(-OpenRouterAudioCatalog.cacheLifetime)
        let cache = try seededCache(updatedAt: updatedAt)
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        StubURLProtocol.handler = { request in
            .status(503, Data("Authorization: Bearer test-secret".utf8), url: request.url!)
        }
        let catalog = catalog(cacheURL: cache)

        XCTAssertTrue(catalog.isStale)
        await catalog.refresh()

        XCTAssertEqual(catalog.models.count, 1)
        XCTAssertEqual(catalog.lastUpdated, updatedAt)
        XCTAssertEqual(catalog.errorMessage, "OpenRouter could not load audio models (HTTP 503).")
        XCTAssertFalse(catalog.isRefreshing)

        StubURLProtocol.handler = { request in
            .respond(
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Length": "\(OpenRouterAudioCatalogSnapshot.maximumBytes + 1)"]
                )!,
                Data()
            )
        }
        await catalog.refresh(force: true)

        XCTAssertEqual(catalog.models.count, 1)
        XCTAssertEqual(catalog.errorMessage, "OpenRouter's audio model catalogue exceeded the download limit.")
        XCTAssertEqual(OpenRouterAudioCatalogSnapshot.read(from: cache, now: now)?.updatedAt, updatedAt)
    }

    @MainActor
    func testFreshCacheSkipsTheNetworkUntilForced() async throws {
        let cache = try seededCache(updatedAt: now)
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let calls = PortableCatalogRequestCount()
        StubURLProtocol.handler = { request in
            await calls.increment()
            return .ok(Data(#"{"data":[]}"#.utf8), url: request.url!)
        }
        let catalog = catalog(cacheURL: cache)

        await catalog.refresh()
        let skipped = await calls.value
        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(catalog.models.count, 1)
        await catalog.refresh(force: true)
        let forced = await calls.value
        XCTAssertEqual(forced, 1)
        XCTAssertTrue(catalog.models.isEmpty)
    }

    @MainActor
    func testUserCancellationStopsAHangingRefreshWithoutPublishingAnError() async {
        let started = expectation(description: "Response headers arrived")
        let stopped = expectation(description: "Hanging network task was cancelled")
        let session = hangingSession(started: started, stopped: stopped)
        defer { session.invalidateAndCancel() }
        let catalog = OpenRouterAudioCatalog(session: session, cacheURL: nil)
        let refresh = Task { await catalog.refresh() }
        await fulfillment(of: [started], timeout: 5)

        refresh.cancel()
        await refresh.value
        await fulfillment(of: [stopped], timeout: 5)

        XCTAssertFalse(catalog.isRefreshing)
        XCTAssertTrue(catalog.models.isEmpty)
        XCTAssertNil(catalog.errorMessage)
        XCTAssertNil(catalog.lastUpdated)
    }

    @MainActor
    func testDeadlineCancelsAHangingBodyAndPreservesStaleMetadata() async throws {
        let cache = try seededCache(updatedAt: now.addingTimeInterval(-30_000))
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let started = expectation(description: "Response headers arrived")
        let stopped = expectation(description: "Hanging network task was cancelled")
        let session = hangingSession(started: started, stopped: stopped)
        defer { session.invalidateAndCancel() }
        let catalog = OpenRouterAudioCatalog(session: session, cacheURL: cache, clock: { self.now })
        catalog.refreshTimeout = .seconds(1)

        await catalog.refresh()
        await fulfillment(of: [started, stopped], timeout: 5)

        XCTAssertFalse(catalog.isRefreshing)
        XCTAssertEqual(catalog.models.map(\.id), ["vendor/retained"])
        XCTAssertEqual(catalog.errorMessage, "OpenRouter audio model discovery timed out. Try again.")
        XCTAssertEqual(OpenRouterAudioCatalogSnapshot.read(from: cache, now: now)?.models, catalog.models)
    }

    @MainActor
    func testOlderResponseCannotOverwriteANewerSuccessfulCache() async throws {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let started = expectation(description: "Older request waits for its response")
        let gate = PortableCatalogResponseGate(started: started)
        StubURLProtocol.handler = { request in
            let isOlder = request.value(forHTTPHeaderField: "Authorization") == "Bearer older"
            if isOlder { await gate.wait() }
            return .ok(Self.catalogue(isOlder ? "vendor/older" : "vendor/newer"), url: request.url!)
        }
        let session = StubURLProtocol.makeSession()
        defer { session.invalidateAndCancel() }
        let first = OpenRouterAudioCatalog(
            apiKeyProvider: { "older" }, session: session, cacheURL: cache, clock: { self.now }
        )
        let second = OpenRouterAudioCatalog(
            apiKeyProvider: { "newer" }, session: session, cacheURL: cache, clock: { self.now }
        )
        let olderRefresh = Task { await first.refresh() }
        await fulfillment(of: [started], timeout: 5)
        await second.refresh()
        await gate.release()
        await olderRefresh.value

        XCTAssertEqual(first.models.map(\.id), ["vendor/older"])
        XCTAssertEqual(second.models.map(\.id), ["vendor/newer"])
        XCTAssertFalse(first.isRefreshing)
        XCTAssertFalse(second.isRefreshing)
        let restored = OpenRouterAudioCatalog(cacheURL: cache, clock: { self.now })
        XCTAssertEqual(restored.models.map(\.id), ["vendor/newer"])
    }

    @MainActor
    func testOverlappingForcedRefreshSupersedesOlderWork() async {
        let started = expectation(description: "First key lookup started")
        let gate = PortableCatalogKeyGate(started: started)
        StubURLProtocol.handler = { request in .ok(Self.catalogue("vendor/stt"), url: request.url!) }
        let catalog = OpenRouterAudioCatalog(
            apiKeyProvider: { await gate.key() }, session: StubURLProtocol.makeSession(), cacheURL: nil,
            clock: { self.now }
        )
        let first = Task { await catalog.refresh() }
        await fulfillment(of: [started], timeout: 5)

        await catalog.refresh(force: true)
        await gate.release()
        await first.value

        XCTAssertEqual(catalog.models.map(\.id), ["vendor/stt"])
        XCTAssertEqual(catalog.lastUpdated, now)
        XCTAssertFalse(catalog.isRefreshing)
        XCTAssertNil(catalog.errorMessage)
    }

    // MARK: - Helpers

    @MainActor
    private func catalog(cacheURL: URL) -> OpenRouterAudioCatalog {
        OpenRouterAudioCatalog(session: StubURLProtocol.makeSession(), cacheURL: cacheURL, clock: { self.now })
    }

    private func hangingSession(started: XCTestExpectation, stopped: XCTestExpectation) -> URLSession {
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        StubURLProtocol.handler = { request in
            .respondWithoutFinishing(
                HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"data":["#.utf8)
            )
        }
        return StubURLProtocol.makeSession()
    }

    private func temporaryCache() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("catalog.json")
    }

    @MainActor
    private func seededCache(updatedAt: Date) throws -> URL {
        let cache = temporaryCache()
        let models = try JSONDecoder().decode(
            OpenRouterAudioModelResponse.self, from: Self.catalogue("vendor/retained")
        ).data
        OpenRouterAudioCatalogSnapshot(version: 1, updatedAt: updatedAt, models: models).write(to: cache)
        return cache
    }

    private static func catalogue(_ identifier: String) -> Data {
        Data("""
        {"data":[{"id":"\(identifier)","architecture":{
          "input_modalities":["audio"],"output_modalities":["transcription"]
        }}]}
        """.utf8)
    }

    private static let mixedCatalogue = """
    {"data":[
      {"id":"vendor/stt","name":"Vendor STT","architecture":{"input_modalities":["audio"],
       "output_modalities":["transcription"]},"pricing":{"audio_second":"0.0001"},"private_field":"ignored"},
      {"id":"vendor/chat","architecture":{"input_modalities":["audio"],"output_modalities":["text","audio"]}},
      {"id":"vendor/tts","architecture":{"input_modalities":["text"],"output_modalities":["speech"]},
       "supported_voices":["voice-one"]},
      {"id":"vendor/stt","name":"Duplicate","architecture":{"input_modalities":["audio"],
       "output_modalities":["transcription"]}},
      {"id":12}
    ]}
    """
}

private actor PortableCatalogRequestCount {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor PortableCatalogResponseGate {
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

private actor PortableCatalogKeyGate {
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
