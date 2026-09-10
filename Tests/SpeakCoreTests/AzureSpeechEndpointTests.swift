import XCTest
@testable import SpeakCore

final class AzureSpeechEndpointTests: XCTestCase {
    func testRegionalEndpoint_normalizesAndUsesHTTPS() {
        XCTAssertEqual(
            AzureSpeechEndpoint.baseURL(region: " EastUS2 ")?.absoluteString,
            "https://eastus2.tts.speech.microsoft.com"
        )
    }

    func testUntrustedRegion_cannotChangeDestination() {
        for region in ["", "evil.example/", "evil.example#", "user@evil.example", "eastus:80",
                       "eastus?x=", "eastus\\evil", "eastus\nother", String(repeating: "a", count: 64)] {
            XCTAssertNil(AzureSpeechEndpoint.baseURL(region: region), region)
        }
    }
}
