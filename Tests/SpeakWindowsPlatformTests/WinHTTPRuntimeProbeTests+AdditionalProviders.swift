import Foundation
import SpeakCore
import SpeakWindowsPlatform
import XCTest

extension WinHTTPRuntimeProbeTests {
    func testAdditionalProvidersDrainExactPCMAndCompleteOnTheirOwnProtocol() async throws {
        try await additionalProviders(scenario: "complete")
    }

    func testAdditionalProvidersRejectNormalClosureWithoutCompletion() async throws {
        try await additionalProviders(scenario: "early")
    }

    private func additionalProviders(scenario: String) async throws {
        guard let value = ProcessInfo.processInfo.environment["JSTI_WEBSOCKET_PROBE_PORT"] else {
            throw XCTSkip("Requires the bounded local WebSocket peer.")
        }
        let port = try XCTUnwrap(Int(value))
        for provider in AdditionalProviderLoopback.Provider.allCases {
            let harness = AdditionalProviderLoopback(provider: provider, port: port, scenario: scenario) {
                WinHTTPStreamingConnection(request: $0)
            }
            defer { harness.client.cancel() }
            let heard = expectation(description: "\(provider) received generated PCM")
            harness.start { heard.fulfill() }
            await fulfillment(of: [heard], timeout: 5)
            let transcript = await harness.client.finishAndWait()
            if scenario == "complete" {
                XCTAssertEqual(transcript, provider.expectedTranscript, "\(provider)")
                XCTAssertTrue(harness.errors.isEmpty, "\(provider): \(harness.errors)")
            } else {
                XCTAssertEqual(transcript, "Before.")
                XCTAssertEqual(harness.errors.count, 1, "\(provider)")
                XCTAssertNotNil(harness.errors.first as? ProviderStreamingError)
            }
        }
    }
}
