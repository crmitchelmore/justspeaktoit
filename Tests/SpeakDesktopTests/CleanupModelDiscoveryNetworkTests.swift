import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class CleanupModelDiscoveryNetworkTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testDisablingCancelsActiveRequestAndCannotPublishLateMetadata() async throws {
        let started = expectation(description: "started")
        let stopped = expectation(description: "cancelled")
        StubURLProtocol.onStartLoading = { started.fulfill() }
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        StubURLProtocol.handler = { request in
            .respondWithoutFinishing(HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, Data("{\"data\":[".utf8))
        }
        let store = CleanupModelDiscoveryStore(session: StubURLProtocol.makeSession(), cacheURL: nil)
        store.setEnabled(true)
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [started], timeout: 2)
        store.setEnabled(false)
        await fulfillment(of: [stopped], timeout: 2)
        await refresh.value
        XCTAssertFalse(store.snapshot.enabled)
        XCTAssertFalse(store.snapshot.isRefreshing)
        XCTAssertTrue(store.snapshot.models.isEmpty)
        XCTAssertNil(store.snapshot.lastUpdated)
    }

    func testTotalDeadlineStopsHangingResponse() async throws {
        let stopped = expectation(description: "deadline cancels task")
        StubURLProtocol.onStopLoading = { stopped.fulfill() }
        StubURLProtocol.handler = { request in
            .respondWithoutFinishing(HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, Data("{\"data\":[".utf8))
        }
        let store = CleanupModelDiscoveryStore(session: StubURLProtocol.makeSession(), cacheURL: nil)
        store.timeout = .milliseconds(100)
        store.setEnabled(true)
        await store.refresh()
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertFalse(store.snapshot.isRefreshing)
        XCTAssertNotNil(store.snapshot.errorMessage)
        XCTAssertEqual(store.options(), ModelCatalog.cloudPostProcessing)
    }

    func testOversizedOrHTTPFailureNeverReplacesBundledModelsOrLeaksErrorBody() async {
        for status in [200, 503] {
            StubURLProtocol.handler = { request in
                .respond(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Length": "\(CleanupModelDiscoveryStore.maximumBytes + 1)"])!,
                    Data("private provider failure".utf8))
            }
            let store = CleanupModelDiscoveryStore(session: StubURLProtocol.makeSession(), cacheURL: nil)
            store.setEnabled(true)
            await store.refresh()
            XCTAssertNotNil(store.snapshot.errorMessage)
            XCTAssertFalse(store.snapshot.errorMessage?.contains("private provider failure") == true)
            XCTAssertEqual(store.options(), ModelCatalog.cloudPostProcessing)
        }
    }
}
