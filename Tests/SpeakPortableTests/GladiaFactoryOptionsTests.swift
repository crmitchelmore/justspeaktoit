import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import SpeakCore

/// The portable native-transport constructor remains inert. The Apple-only
/// factory overloads are covered by GladiaAppleFactoryOptionsTests.
final class GladiaFactoryOptionsTests: XCTestCase {
    func testNativeTransportOptionsOverloadSelectsCanonicalCheckedSchedulerWithoutStartingIO() {
        let client = GladiaLiveClient(
            apiKey: "synthetic", options: LiveClientOptions(),
            initiateSession: { _, _ in XCTFail("Construction must not initiate HTTP"); return NeverSessionRequest() },
            makeConnection: { _ in XCTFail("Construction must not create a socket"); return NeverSocket() }
        )
        XCTAssertTrue(client.usesCheckedDefaultScheduler)
        XCTAssertEqual(client.finalisationBudget, 4.5)
        XCTAssertEqual(client.currentStage, .idle)
    }
}

private final class NeverSessionRequest: GladiaLiveSessionRequest {
    func cancel() {}
}
private final class NeverSocket: StreamingWebSocketConnection {
    func resume(onOpen: @escaping @Sendable () -> Void) { XCTFail("Unexpected socket resume") }
    func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {}
    func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {}
    func cancel() {}
}
