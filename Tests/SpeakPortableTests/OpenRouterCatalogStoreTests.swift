import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class OpenRouterCatalogStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testDetachedConsumerLoadsCacheSkipsFreshNetworkAndRefreshesWithoutMainActor() async throws {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let models = try JSONDecoder().decode(
            OpenRouterAudioModelResponse.self, from: Self.payload("vendor/cached")
        ).data
        OpenRouterAudioCatalogSnapshot(version: 1, updatedAt: now, models: models).write(to: cache)
        StubURLProtocol.handler = { request in .ok(Self.payload("vendor/refreshed"), url: request.url!) }
        let now = now
        let result = await Task.detached {
            let store = OpenRouterAudioCatalogStore(
                apiKeyProvider: { XCTAssertFalse(Thread.isMainThread); return nil },
                session: StubURLProtocol.makeSession(), cacheURL: cache, clock: { now }
            )
            XCTAssertEqual(store.snapshot.models.map(\.id), ["vendor/cached"])
            XCTAssertFalse(store.isStale)
            await store.refresh()
            XCTAssertTrue(StubURLProtocol.recordedRequests.isEmpty)
            return await store.refresh(force: true)
        }.value
        XCTAssertEqual(result.models(for: .transcription).map(\.id), ["vendor/refreshed"])
        XCTAssertFalse(result.isRefreshing)
        XCTAssertNil(result.errorMessage)
    }

    func testCancelledStoreRefreshPreservesCacheAndClearsRefreshState() async throws {
        let started = expectation(description: "Refresh begins")
        let stopped = expectation(description: "Refresh cancelled")
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        StubURLProtocol.handler = { _ in .hang }
        let store = OpenRouterAudioCatalogStore(session: StubURLProtocol.makeSession(), cacheURL: nil)
        let task = Task.detached { await store.refresh() }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(store.snapshot.isRefreshing)
        task.cancel()
        let state = await task.value
        await fulfillment(of: [stopped], timeout: 5)
        XCTAssertFalse(state.isRefreshing)
        XCTAssertNil(state.errorMessage)
        XCTAssertNil(state.lastUpdated)
    }

    func testStoreSupersedesAStalledKeyLookupWithoutPublishingOlderState() async throws {
        let started = expectation(description: "Old key lookup started")
        let gate = OpenRouterStoreGate(started: started)
        StubURLProtocol.handler = { request in .ok(Self.payload("vendor/new"), url: request.url!) }
        let store = OpenRouterAudioCatalogStore(
            apiKeyProvider: { await gate.key() }, session: StubURLProtocol.makeSession(), cacheURL: nil
        )
        let first = Task.detached { await store.refresh() }
        await fulfillment(of: [started], timeout: 5)
        let newer = await store.refresh(force: true)
        await gate.release()
        let completed = await first.value
        XCTAssertEqual(newer.models.map(\.id), ["vendor/new"])
        XCTAssertEqual(completed.models, newer.models)
        XCTAssertEqual(store.snapshot.models, newer.models)
        XCTAssertFalse(store.snapshot.isRefreshing)
        XCTAssertEqual(StubURLProtocol.recordedRequests.count, 1)
    }

    @MainActor
    func testOlderDetachedStoreCannotOverwriteNewerAppleCacheWhenClockMovesBackwards() async throws {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let started = expectation(description: "Older store waits")
        let gate = OpenRouterStoreGate(started: started)
        StubURLProtocol.handler = { request in
            let older = request.value(forHTTPHeaderField: "Authorization") == "Bearer older"
            if older { _ = await gate.key() }
            return .ok(Self.payload(older ? "vendor/old" : "vendor/new"), url: request.url!)
        }
        let now = now
        let store = OpenRouterAudioCatalogStore(
            apiKeyProvider: { "older" }, session: StubURLProtocol.makeSession(), cacheURL: cache, clock: { now }
        )
        let facade = OpenRouterAudioCatalog(
            session: StubURLProtocol.makeSession(), cacheURL: cache, clock: { now.addingTimeInterval(-10) }
        )
        let older = Task.detached { await store.refresh() }
        await fulfillment(of: [started], timeout: 5)
        await facade.refresh()
        await gate.release()
        await older.value
        XCTAssertEqual(store.snapshot.models.map(\.id), ["vendor/old"])
        XCTAssertEqual(facade.models.map(\.id), ["vendor/new"])
        XCTAssertEqual(OpenRouterAudioCatalogSnapshot.read(from: cache, now: now)?.models, facade.models)
    }

    func testFailedRefreshKeepsCacheWhileSuccessfulEmptyRefreshRetiresIt() async throws {
        StubURLProtocol.handler = { request in .ok(Self.payload("vendor/retained"), url: request.url!) }
        let store = OpenRouterAudioCatalogStore(session: StubURLProtocol.makeSession(), cacheURL: nil)
        await store.refresh()
        StubURLProtocol.handler = { request in .ok(Data(#"{"data":[null]}"#.utf8), url: request.url!) }
        let failed = await store.refresh(force: true)
        XCTAssertEqual(failed.models.map(\.id), ["vendor/retained"])
        XCTAssertNotNil(failed.errorMessage)
        StubURLProtocol.handler = { request in .ok(Data(#"{"data":[]}"#.utf8), url: request.url!) }
        let retired = await store.refresh(force: true)
        XCTAssertTrue(retired.models.isEmpty)
        XCTAssertNil(retired.errorMessage)
    }

    private func temporaryCache() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("catalog.json")
    }

    private static func payload(_ id: String) -> Data {
        Data("""
        {"data":[{"id":"\(id)","architecture":{"input_modalities":["audio"],"output_modalities":["transcription"]}}]}
        """.utf8)
    }
}

private actor OpenRouterStoreGate {
    let started: XCTestExpectation
    var calls = 0
    var continuation: CheckedContinuation<String?, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func key() async -> String? {
        calls += 1
        guard calls == 1 else { return nil }
        return await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func release() { continuation?.resume(returning: nil); continuation = nil }
}
