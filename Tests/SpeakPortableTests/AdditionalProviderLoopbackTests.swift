import Foundation
import SpeakTestSupport
import XCTest
@testable import SpeakCore

final class AdditionalProviderLoopbackTests: XCTestCase {
    func testNativeAppleProviderCompletionAndEarlyClosure() async throws {
        #if canImport(FoundationNetworking)
        throw XCTSkip("FoundationNetworking is not a qualified socket; Linux uses NIO, Windows uses WinHTTP.")
        #else
        guard let value = ProcessInfo.processInfo.environment["JSTI_WEBSOCKET_PROBE_PORT"] else {
            throw XCTSkip("Requires the bounded local WebSocket peer.")
        }
        let port = try XCTUnwrap(Int(value))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for provider in AdditionalProviderLoopback.Provider.allCases {
            for scenario in ["complete", "early"] {
                let harness = AdditionalProviderLoopback(provider: provider, port: port, scenario: scenario) {
                    URLSessionStreamingConnection(session: session, request: $0)
                }
                defer { harness.client.cancel() }
                let heard = expectation(description: "\(provider) received generated PCM")
                harness.start { heard.fulfill() }
                await fulfillment(of: [heard], timeout: 5)
                let transcript = await harness.client.finishAndWait()
                XCTAssertEqual(transcript, scenario == "complete" ? provider.expectedTranscript : "Before.")
                XCTAssertEqual(harness.errors.count, scenario == "complete" ? 0 : 1, "\(provider)")
            }
        }
        #endif
    }
}
