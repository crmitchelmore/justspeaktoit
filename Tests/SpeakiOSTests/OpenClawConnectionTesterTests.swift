import XCTest

@testable import SpeakiOSLib

final class OpenClawConnectionTesterTests: XCTestCase {
    func testNormalisedURL_addsWebSocketSchemeForBareHost() {
        let url = OpenClawConnectionTester.normalisedURL(from: "gateway.example.com:18789")

        XCTAssertEqual(url?.absoluteString, "ws://gateway.example.com:18789")
    }

    func testNormalisedURL_rewritesHTTPSchemeToSecureWebSocket() {
        let url = OpenClawConnectionTester.normalisedURL(from: "https://gateway.example.com/socket")

        XCTAssertEqual(url?.absoluteString, "wss://gateway.example.com/socket")
    }

    func testEvaluateConnectResponse_returnsFailureMessageFromGatewayError() {
        let result = OpenClawConnectionTester.evaluateConnectResponse(
            ["error": ["message": "bad token"]],
            elapsed: 25
        )

        XCTAssertEqual(result, .failure("bad token"))
    }

    func testEvaluateConnectResponse_returnsSuccessWithElapsedTime() {
        let result = OpenClawConnectionTester.evaluateConnectResponse(["ok": true], elapsed: 42)

        XCTAssertEqual(result, .success("Connected (42ms)"))
    }

    func testEvaluateConnectResponse_returnsUnexpectedResponseWhenGatewayPayloadIsUnknown() {
        let result = OpenClawConnectionTester.evaluateConnectResponse(["event": "connect.challenge"], elapsed: 12)

        XCTAssertEqual(result, .failure("Unexpected response"))
    }
}
