import Foundation
import XCTest
import SpeakCore
@testable import SpeakWindowsPlatform

/// The native bridge's recorded close status reaches shared providers through
/// the close-reporting seam; failures without a close frame report none.
final class WinHTTPCloseReportingTests: XCTestCase {
    func testPeerCloseStatusIsReportedThroughTheSharedSeam() {
        let closed: Error = WinHTTPWebSocketError(
            "The server closed the WebSocket (1000).", closeCode: 1_000, closeReason: "stream-complete"
        )
        XCTAssertEqual((closed as? StreamingWebSocketCloseReporting)?.webSocketCloseCode, 1_000)
        let abnormal: Error = WinHTTPWebSocketError("The server closed the WebSocket (1011).", closeCode: 1_011)
        XCTAssertEqual((abnormal as? StreamingWebSocketCloseReporting)?.webSocketCloseCode, 1_011)
    }

    func testFailureWithoutACloseFrameReportsNoStatus() {
        let failed: Error = WinHTTPWebSocketError("Windows WebSocket failed.")
        XCTAssertNotNil(failed as? StreamingWebSocketCloseReporting)
        XCTAssertNil((failed as? StreamingWebSocketCloseReporting)?.webSocketCloseCode)
        XCTAssertNil((CancellationError() as Error) as? StreamingWebSocketCloseReporting)
    }

    func testExistingErrorFieldsAreUnchanged() {
        let error = WinHTTPWebSocketError(
            "The server closed the WebSocket (1000).", closeCode: 1_000, closeReason: "done"
        )
        XCTAssertEqual(error.message, "The server closed the WebSocket (1000).")
        XCTAssertEqual(error.closeCode, 1_000)
        XCTAssertEqual(error.closeReason, "done")
        XCTAssertEqual(error.errorDescription, "The server closed the WebSocket (1000).")
    }
}
