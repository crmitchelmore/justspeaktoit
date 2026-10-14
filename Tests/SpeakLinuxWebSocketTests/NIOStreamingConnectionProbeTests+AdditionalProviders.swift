import Foundation
import SpeakCore
import SpeakLinuxWebSocket
import XCTest

extension NIOStreamingConnectionProbeTests {
    func testAdditionalProvidersDrainExactPCMAndCompleteOnTheirOwnProtocol() async throws {
        try await additionalProviders(scenario: "complete")
    }

    func testAdditionalProvidersRejectNormalClosureWithoutCompletion() async throws {
        try await additionalProviders(scenario: "early")
    }

    private func additionalProviders(scenario: String) async throws {
        let port = try XCTUnwrap(probePort)
        for provider in AdditionalProviderLoopback.Provider.allCases {
            let harness = AdditionalProviderLoopback(provider: provider, port: port, scenario: scenario) {
                NIOStreamingConnection(request: $0)
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
