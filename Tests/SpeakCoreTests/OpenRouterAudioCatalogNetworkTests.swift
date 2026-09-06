import Foundation
import XCTest
@testable import SpeakCore

@MainActor
final class OpenRouterAudioCatalogNetworkTests: XCTestCase {
    func testWallDeadline_CancelsHangingBodyAndPreservesStaleMetadata() async throws {
        let cache = try seededCache()
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let started = expectation(description: "Response headers arrived")
        let stopped = expectation(description: "Hanging network task was cancelled")
        let finished = expectation(description: "Refresh returned before request inactivity timeout")
        let session = hangingSession(started: started, stopped: stopped)
        defer { finish(session) }
        let catalog = OpenRouterAudioCatalog(session: session, cacheURL: cache)
        catalog.refreshTimeout = .seconds(1)
        let refresh = Task {
            await catalog.refresh()
            finished.fulfill()
        }

        await fulfillment(of: [started, stopped, finished], timeout: 4)
        // Also clean up if the deadline regresses; the protocol owns no suspended continuations or detached work.
        refresh.cancel()
        await refresh.value

        XCTAssertFalse(catalog.isRefreshing)
        XCTAssertTrue(catalog.isStale)
        XCTAssertEqual(catalog.models.map(\.id), ["vendor/retained"])
        XCTAssertEqual(catalog.errorMessage, "OpenRouter audio model discovery timed out. Try again.")
        let cached = OpenRouterAudioCatalogSnapshot.read(from: cache, now: Date())
        XCTAssertEqual(cached?.models, catalog.models)
        XCTAssertEqual(cached?.updatedAt, catalog.lastUpdated)
    }

    func testUserCancellation_StopsHangingBodyWithoutPublishingError() async {
        let started = expectation(description: "Response headers arrived")
        let stopped = expectation(description: "Hanging network task was cancelled")
        let finished = expectation(description: "Cancelled refresh returned")
        let session = hangingSession(started: started, stopped: stopped)
        defer { finish(session) }
        let catalog = OpenRouterAudioCatalog(session: session, cacheURL: nil)
        let refresh = Task {
            await catalog.refresh()
            finished.fulfill()
        }
        await fulfillment(of: [started], timeout: 2)

        refresh.cancel()
        await fulfillment(of: [stopped, finished], timeout: 2)
        await refresh.value

        XCTAssertFalse(catalog.isRefreshing)
        XCTAssertTrue(catalog.models.isEmpty)
        XCTAssertNil(catalog.errorMessage)
        XCTAssertNil(catalog.lastUpdated)
    }

    private func hangingSession(started: XCTestExpectation, stopped: XCTestExpectation) -> URLSession {
        OpenRouterCatalogHangingProtocol.didStart = { started.fulfill() }
        OpenRouterCatalogHangingProtocol.didStop = { stopped.fulfill() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterCatalogHangingProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func finish(_ session: URLSession) {
        session.invalidateAndCancel()
        OpenRouterCatalogHangingProtocol.didStart = nil
        OpenRouterCatalogHangingProtocol.didStop = nil
    }

    private func seededCache() throws -> URL {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("catalog.json")
        let body = """
        {"data":[{"id":"vendor/retained","architecture":{
          "input_modalities":["audio"],"output_modalities":["transcription"]
        }}]}
        """
        let models = try JSONDecoder().decode(OpenRouterAudioModelResponse.self, from: Data(body.utf8)).data
        OpenRouterAudioCatalogSnapshot(
            version: 1, updatedAt: Date().addingTimeInterval(-30_000), models: models
        ).write(to: cache)
        return cache
    }
}

/// Produces headers and an incomplete JSON chunk, then waits for URLSession to cancel it.
/// No continuation, timer, or background task survives stopLoading.
private final class OpenRouterCatalogHangingProtocol: URLProtocol {
    nonisolated(unsafe) static var didStart: (@Sendable () -> Void)?
    nonisolated(unsafe) static var didStop: (@Sendable () -> Void)?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":["#.utf8))
        Self.didStart?()
    }

    override func stopLoading() { Self.didStop?() }
}
